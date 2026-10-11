import CMUXAgentLaunch
import Darwin
import Foundation

extension CMUXCLI {
    /// `cmux local-tmux __recover`, typed by session restore into the fresh
    /// shell of a terminal whose local-tmux server is gone.
    ///
    /// It recreates the terminal's persistent session and resumes the saved
    /// conversation inside it, so the recovered agent survives the next app
    /// quit or crash. When persistence cannot be recreated, the conversation
    /// is resumed in this terminal instead; `cmux restore` enforces the same
    /// single-launch admission either way.
    func runLocalTmuxRecovery(
        arguments: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard let recovery = LocalTmuxRecoveryCommand(arguments: arguments) else {
            throw CLIError(message: String(
                localized: "cli.localTmux.recover.error.invalid",
                defaultValue: "local-tmux recovery received invalid arguments; nothing was started"
            ))
        }
        let environment = ProcessInfo.processInfo.environment
        guard let surfaceID = environment["CMUX_SURFACE_ID"].flatMap(UUID.init(uuidString:)),
              let workspaceID = environment["CMUX_WORKSPACE_ID"].flatMap(UUID.init(uuidString:)) else {
            throw CLIError(message: String(
                localized: "cli.localTmux.recover.error.noSurface",
                defaultValue: "local-tmux recovery must run in the cmux terminal being restored"
            ))
        }
        do {
            try recoverLocalTmuxSession(
                recovery,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                environment: environment,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
        } catch {
            FileHandle.standardError.write(Data((String.localizedStringWithFormat(
                String(
                    localized: "cli.localTmux.recover.fallback",
                    defaultValue: "cmux could not recreate this terminal's local-tmux session (%@). Resuming the saved conversation here without persistence."
                ),
                String(describing: error)
            ) + "\n").utf8))
            execLocalTmuxRecoveryFallback(recovery, surfaceID: surfaceID)
        }
    }

    private func recoverLocalTmuxSession(
        _ recovery: LocalTmuxRecoveryCommand,
        surfaceID: UUID,
        workspaceID: UUID,
        environment: [String: String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let registry = LocalTmuxSessionRegistry.live()
        let (_, builder, runner) = try localTmuxRuntime(registry: registry)
        let resolver = LocalTmuxSessionIdentityResolver(registry: registry, builder: builder, runner: runner)
        let previous = try registry.load().first {
            $0.tmuxBinding?.serverID == recovery.serverID
                && $0.tmuxBinding?.sessionID.rawValue == recovery.sessionID
        }
        // Responding to the respawn closes this terminal's PTY.
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        let request = LocalSessionAttachRequest(
            workspace: workspaceID.uuidString,
            surface: surfaceID.uuidString,
            pane: nil,
            window: nil,
            focus: false
        )
        // Restore saw this session as gone. If it is somehow live again,
        // reattach to it rather than start a second copy of its work.
        if let previous, case .live(let session)? = try? resolver.resolve(previous) {
            try attachLocalPersistentSession(
                record: session.record,
                attachCommand: builder.attachCommand(binding: session.binding),
                socketPath: builder.socketPath,
                request: request,
                profile: .localTmux,
                registry: registry,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
            return
        }

        // Never adopt a live session that merely reuses the old name.
        let baseName = previous?.name ?? "recovered-\(surfaceID.uuidString.prefix(8).lowercased())"
        var name = baseName
        if try runner.run(arguments: builder.hasSessionArguments(name)).succeeded {
            name = "\(baseName)-\(UUID().uuidString.prefix(6).lowercased())"
        }
        name = try LocalTmuxSessionNameValidator().validate(name)
        var cwd = FileManager.default.currentDirectoryPath
        var isDirectory = ObjCBool(false)
        if let saved = previous?.cwd,
           FileManager.default.fileExists(atPath: saved, isDirectory: &isDirectory),
           isDirectory.boolValue {
            cwd = saved
        }

        let channel = LocalTmuxRecoveryCommand.attachChannel(nonce: UUID())
        let paneCommand = recovery.paneCommand(
            tmuxPath: builder.tmuxPath,
            socketPath: builder.socketPath,
            cliPath: localTmuxRecoveryCLIPath(environment: environment),
            surfaceID: surfaceID,
            channel: channel
        )
        _ = try runner.requireSuccess(
            builder.newSessionArguments(
                sessionName: name,
                workingDirectory: cwd,
                command: paneCommand,
                environment: LocalTmuxSessionEnvironment(environment: environment)
            ) + LocalTmuxRecoveryCommand.attachHookArguments(channel: channel),
            context: "start"
        )
        let observed: LocalTmuxSessionIdentityResolver.ObservedSession
        do {
            observed = try resolver.observedSession(named: name)
        } catch {
            _ = try? runner.run(arguments: builder.killSessionArguments(sessionName: name))
            throw error
        }
        do {
            _ = try? runner.requireSuccess(
                builder.historyLimitArguments(binding: observed.binding),
                context: "configure history"
            )
            // Keep the logical record (and its ID) when the name is unchanged;
            // a renamed replacement gets its own record and the old one stays
            // stale for `cleanup`.
            var record = previous.flatMap { $0.name == name ? $0 : nil }
                ?? LocalTmuxSessionRecord(name: name, socketPath: builder.socketPath, cwd: cwd)
            record.tmuxBinding = observed.binding
            record.socketPath = builder.socketPath
            record.cwd = cwd
            record.updatedAt = Date.now.timeIntervalSince1970
            try registry.upsert(record)
            try attachLocalPersistentSession(
                record: record,
                attachCommand: builder.attachCommand(binding: observed.binding),
                socketPath: builder.socketPath,
                request: request,
                profile: .localTmux,
                registry: registry,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
        } catch {
            // The replacement pane is still waiting for an attach; remove it
            // so it cannot start a second resume later.
            _ = try? runner.run(arguments: builder.killSessionArguments(binding: observed.binding))
            throw error
        }
    }

    /// The bundled CLI that the replacement pane runs `restore` with.
    private func localTmuxRecoveryCLIPath(environment: [String: String]) -> String {
        if let bundled = environment["CMUX_BUNDLED_CLI_PATH"], FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    /// Resumes the conversation in this terminal when persistence could not be recreated.
    private func execLocalTmuxRecoveryFallback(_ recovery: LocalTmuxRecoveryCommand, surfaceID: UUID) -> Never {
        let executable = localTmuxRecoveryCLIPath(environment: ProcessInfo.processInfo.environment)
        let arguments = [executable, "restore", "--surface", surfaceID.uuidString, recovery.agentKind, recovery.checkpointID]
        var cArguments = arguments.map { strdup($0) } + [nil]
        execv(executable, &cArguments)
        exit(127)
    }
}
