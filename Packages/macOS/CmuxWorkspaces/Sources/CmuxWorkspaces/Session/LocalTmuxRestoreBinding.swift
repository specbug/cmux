public import Foundation

/// The tmux identity encoded in a cmux local-tmux attach command.
///
/// The local-tmux profile persists one guarded attach command per client
/// surface. Its server incarnation marker and immutable `$N` session ID are the
/// only facts that may identify the durable session again: a session name can
/// be reused, and a restarted server can reuse `$N`, but it can never inherit
/// the random server marker.
public struct LocalTmuxRestoreBinding: Hashable, Sendable {
    /// Absolute path of the tmux executable the command runs.
    public let tmuxPath: String
    /// Absolute path of the profile's private tmux server socket.
    public let socketPath: String
    /// Random marker stored only in the memory of the server that created the session.
    public let serverID: UUID
    /// Immutable tmux session ID, such as `$3`.
    public let sessionID: String

    /// Creates a binding from already validated command fields.
    ///
    /// - Parameters:
    ///   - tmuxPath: Absolute tmux executable path.
    ///   - socketPath: Absolute tmux socket path.
    ///   - serverID: Server incarnation marker.
    ///   - sessionID: Immutable tmux session ID.
    public init(tmuxPath: String, socketPath: String, serverID: UUID, sessionID: String) {
        self.tmuxPath = tmuxPath
        self.socketPath = socketPath
        self.serverID = serverID
        self.sessionID = sessionID
    }

    /// The tmux server endpoint shared by every binding on the same socket.
    var endpoint: LocalTmuxServerEndpoint {
        LocalTmuxServerEndpoint(tmuxPath: tmuxPath, socketPath: socketPath)
    }
}
