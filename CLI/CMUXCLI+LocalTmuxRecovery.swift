import CMUXAgentLaunch
import Darwin
import Foundation

extension CMUXCLI {
    /// `cmux local-tmux __recover`, typed by session restore into the fresh
    /// shell of a terminal whose local-tmux server is gone.
    ///
    /// It recreates the terminal's persistent session in the original profile
    /// and becomes the terminal's tmux client, so the recovered conversation
    /// survives the next app quit or crash. The terminal is never respawned:
    /// respawning would discard the restore record that the replacement pane's
    /// `cmux restore --surface` needs. When persistence cannot be recreated,
    /// the conversation is resumed in this terminal instead; `cmux restore`
    /// enforces the same single-launch admission either way.
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
                client: client
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
        client: SocketClient
    ) throws {
        // The persisted attach command named the profile: its socket's
        // directory is the registry, and its tmux binary owns the server.
        let registry = LocalTmuxSessionRegistry(
            rootURL: URL(fileURLWithPath: recovery.socketPath).deletingLastPathComponent()
        )
        let (_, builder, runner) = try localTmuxRuntime(registry: registry, tmuxPath: recovery.tmuxPath)
        let planner = LocalTmuxSessionRecovery(registry: registry, builder: builder, runner: runner)
        let prepared = try planner.prepare(
            recovery,
            surfaceID: surfaceID,
            cliPath: localTmuxRecoveryCLIPath(environment: environment),
            environment: environment,
            workingDirectory: FileManager.default.currentDirectoryPath
        )
        do {
            // Record the new attach command on this terminal in place; its
            // panel, restore record, and agent checkpoint stay untouched.
            _ = try client.sendV2(method: "surface.local_tmux_adopt", params: [
                "workspace_id": workspaceID.uuidString,
                "surface_id": surfaceID.uuidString,
                "tmux_start_command": builder.attachCommand(binding: prepared.binding),
            ])
            _ = try? registry.recordAttachment(
                id: prepared.record.id,
                workspaceID: workspaceID.uuidString,
                workspaceTitle: prepared.record.workspaceTitle,
                surfaceID: surfaceID.uuidString
            )
        } catch {
            planner.discard(prepared)
            throw error
        }
        client.close()
        // Become the terminal's tmux client, exactly as its attach command
        // would on the next restore. Attaching releases the waiting pane.
        unsetenv("TMUX")
        setenv("CMUX_LOCAL_TMUX", "1", 1)
        var cArguments = ([builder.tmuxPath] + builder.attachArguments(binding: prepared.binding))
            .map { strdup($0) } + [nil]
        execv(builder.tmuxPath, &cArguments)
        planner.discard(prepared)
        throw CLIError(message: String(cString: strerror(errno)))
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
