import Foundation

/// One tmux client executable and server socket that a liveness probe queries once.
struct LocalTmuxServerEndpoint: Hashable, Sendable {
    let tmuxPath: String
    let socketPath: String

    /// Lists every session with the server marker in one request that never starts a server.
    ///
    /// Fields are separated by a space rather than a tab: without a UTF-8
    /// locale (common for GUI-launched apps) tmux replaces control characters
    /// in formatted output with `_`. Neither field can contain a space.
    var listSessionsArguments: [String] {
        [
            "-S", socketPath, "list-sessions", "-F",
            "#{session_id} #{\(LocalTmuxRestoreLivenessClassifier.serverIdentityOption)}",
        ]
    }
}
