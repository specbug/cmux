import Foundation

/// Decides whether persisted local-tmux bindings are live, ended, or unknown.
///
/// Only conclusive evidence produces ``LocalTmuxRestoreLiveness/ended``: the
/// socket is absent, tmux reports that no server is listening, or the server
/// that answers does not carry the binding's incarnation marker and session.
/// Timeouts, a missing client executable next to an existing socket, and any
/// unrecognized error stay ``LocalTmuxRestoreLiveness/unknown`` so restore
/// keeps the guarded attach command instead of launching a second copy of
/// work that may still be running.
public struct LocalTmuxRestoreLivenessClassifier: Sendable {
    static let serverIdentityOption = "@cmux_local_server_id"

    /// Creates a classifier.
    public init() {}

    /// Classifies every binding that shares one server endpoint.
    ///
    /// - Parameters:
    ///   - bindings: Bindings that use the same tmux executable and socket.
    ///   - outcome: The single probe result for that endpoint.
    /// - Returns: A decision for each binding.
    public func classify(
        _ bindings: Set<LocalTmuxRestoreBinding>,
        outcome: LocalTmuxServerProbeOutcome
    ) -> [LocalTmuxRestoreBinding: LocalTmuxRestoreLiveness] {
        let decision = serverDecision(outcome)
        var result: [LocalTmuxRestoreBinding: LocalTmuxRestoreLiveness] = [:]
        for binding in bindings {
            switch decision {
            case .ended:
                result[binding] = .ended
            case .unknown:
                result[binding] = .unknown
            case .sessions(let sessions):
                let key = ServerSession(serverID: binding.serverID, sessionID: binding.sessionID)
                result[binding] = sessions.contains(key) ? .live : .ended
            }
        }
        return result
    }

    private struct ServerSession: Hashable {
        let serverID: UUID
        let sessionID: String
    }

    private enum ServerDecision {
        case ended
        case unknown
        case sessions(Set<ServerSession>)
    }

    private func serverDecision(_ outcome: LocalTmuxServerProbeOutcome) -> ServerDecision {
        // No listener can exist without its socket entry, and the attach
        // command could not reach one either.
        guard outcome.socketExists else { return .ended }
        guard outcome.launched, !outcome.timedOut, let status = outcome.exitStatus else {
            return .unknown
        }
        if status == 0 {
            return parsedSessions(outcome.standardOutput).map(ServerDecision.sessions) ?? .unknown
        }
        return serverIsAbsent(outcome.standardError) ? .ended : .unknown
    }

    /// Parses `#{session_id} #{@cmux_local_server_id}` rows.
    ///
    /// A server without the marker (an unmanaged server on this socket) yields
    /// rows with an empty marker; those can never match a persisted binding.
    private func parsedSessions(_ output: String) -> Set<ServerSession>? {
        var sessions = Set<ServerSession>()
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  fields[0].range(of: "^\\$[0-9]+$", options: .regularExpression) != nil else {
                return nil
            }
            let marker = String(fields[1])
            guard !marker.isEmpty else { continue }
            guard let serverID = UUID(uuidString: marker) else { return nil }
            sessions.insert(ServerSession(serverID: serverID, sessionID: String(fields[0])))
        }
        return sessions
    }

    /// Matches the tmux client diagnostics for a socket with no listening server.
    ///
    /// tmux prints `no server running on <path>` when `connect(2)` fails with
    /// `ENOENT` or `ECONNREFUSED`; a stale socket file left by a server that
    /// died with the machine produces the latter. Other connection failures,
    /// such as a permission error, are not proof that the server is gone.
    private func serverIsAbsent(_ standardError: String) -> Bool {
        for line in standardError.split(whereSeparator: \.isNewline) {
            let text = line.lowercased()
            if text.hasPrefix("no server running on ") {
                return true
            }
            if text.hasPrefix("error connecting to "),
               text.hasSuffix("(connection refused)") || text.hasSuffix("(no such file or directory)") {
                return true
            }
        }
        return false
    }
}
