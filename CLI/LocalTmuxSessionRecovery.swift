import CMUXAgentLaunch
import Foundation

/// Finds or creates the session a terminal attaches to during cold recovery.
///
/// This is the profile-side half of `cmux local-tmux __recover`; it never
/// talks to the cmux app. Lookup, creation, and registry rebinding run under
/// the profile's recovery lock so that every terminal of one dead session
/// converges on a single replacement.
struct LocalTmuxSessionRecovery {
    /// The session to attach to.
    struct Prepared {
        let record: LocalTmuxSessionRecord
        let binding: LocalTmuxSessionBinding
        /// Whether this call created the session (and so may remove it again).
        let created: Bool
    }

    /// Recovery history kept per record.
    static let recoveredHistoryLimit = 16

    let registry: LocalTmuxSessionRegistry
    let builder: LocalTmuxCommandBuilder
    let runner: LocalTmuxProcessRunner

    /// Returns the live replacement for a dead session, creating it when needed.
    ///
    /// - Parameters:
    ///   - recovery: The dead binding and the conversation to resume.
    ///   - surfaceID: The terminal that owns the saved conversation.
    ///   - cliPath: The bundled CLI the replacement pane runs `restore` with.
    ///   - environment: The terminal's environment, filtered to the session allowlist.
    ///   - workingDirectory: Fallback cwd when the record's directory is gone.
    /// - Returns: The record and binding to attach to.
    func prepare(
        _ recovery: LocalTmuxRecoveryCommand,
        surfaceID: UUID,
        cliPath: String,
        environment: [String: String],
        workingDirectory: String
    ) throws -> Prepared {
        let dead = LocalTmuxSessionRecord.RecoveredSession(
            serverID: recovery.serverID,
            sessionID: recovery.sessionID
        )
        return try registry.withRecoveryLock {
            let resolver = LocalTmuxSessionIdentityResolver(registry: registry, builder: builder, runner: runner)
            let records = try registry.load()
            // A record that already replaced this session wins over the stale
            // record still holding it, so later terminals converge.
            let previous = records.first { $0.recoveredFrom?.contains(dead) == true }
                ?? records.first {
                    $0.tmuxBinding?.serverID == dead.serverID
                        && $0.tmuxBinding?.sessionID.rawValue == dead.sessionID
                }
            if let previous, case .live(let session)? = try? resolver.resolve(previous) {
                return Prepared(record: session.record, binding: session.binding, created: false)
            }

            // Never adopt a live session that merely reuses the old name.
            let baseName = previous?.name ?? "recovered-\(surfaceID.uuidString.prefix(8).lowercased())"
            var name = baseName
            if try runner.run(arguments: builder.hasSessionArguments(name)).succeeded {
                name = "\(baseName)-\(UUID().uuidString.prefix(6).lowercased())"
            }
            name = try LocalTmuxSessionNameValidator().validate(name)
            var cwd = workingDirectory
            var isDirectory = ObjCBool(false)
            if let saved = previous?.cwd,
               FileManager.default.fileExists(atPath: saved, isDirectory: &isDirectory),
               isDirectory.boolValue {
                cwd = saved
            }

            let channel = LocalTmuxRecoveryCommand.attachChannel(nonce: UUID())
            // Commands run inside the session address the same profile.
            var sessionEnvironment = environment
            sessionEnvironment["CMUX_LOCAL_TMUX_STATE_DIR"] = registry.rootURL.path
            sessionEnvironment["CMUX_LOCAL_TMUX_BIN"] = builder.tmuxPath
            _ = try runner.requireSuccess(
                builder.newSessionArguments(
                    sessionName: name,
                    workingDirectory: cwd,
                    command: recovery.paneCommand(cliPath: cliPath, surfaceID: surfaceID, channel: channel),
                    environment: LocalTmuxSessionEnvironment(environment: sessionEnvironment)
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
                // Keep the logical record (and its ID) when the name is
                // unchanged; a renamed replacement gets its own record.
                var record = previous.flatMap { $0.name == name ? $0 : nil }
                    ?? LocalTmuxSessionRecord(name: name, socketPath: builder.socketPath, cwd: cwd)
                var recovered = previous?.recoveredFrom ?? []
                if let replaced = previous?.tmuxBinding {
                    recovered.append(.init(serverID: replaced.serverID, sessionID: replaced.sessionID.rawValue))
                }
                recovered.append(dead)
                var seen = Set<LocalTmuxSessionRecord.RecoveredSession>()
                recovered = recovered.filter { seen.insert($0).inserted }
                record.recoveredFrom = Array(recovered.suffix(Self.recoveredHistoryLimit))
                record.tmuxBinding = observed.binding
                record.socketPath = builder.socketPath
                record.cwd = cwd
                record.updatedAt = Date.now.timeIntervalSince1970
                try registry.upsert(record)
                return Prepared(record: record, binding: observed.binding, created: true)
            } catch {
                _ = try? runner.run(arguments: builder.killSessionArguments(binding: observed.binding))
                throw error
            }
        }
    }

    /// Removes a session this recovery created when the terminal could not
    /// switch to it, so its waiting pane can never start a second resume.
    func discard(_ prepared: Prepared) {
        guard prepared.created else { return }
        _ = try? runner.run(arguments: builder.killSessionArguments(binding: prepared.binding))
    }
}
