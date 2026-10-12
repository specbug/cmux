/// Raw result of one `tmux list-sessions` probe against a profile socket.
public struct LocalTmuxServerProbeOutcome: Equatable, Sendable {
    /// Whether a filesystem entry existed at the socket path before probing.
    public var socketExists: Bool
    /// Whether the tmux client could be started at all.
    public var launched: Bool
    /// Whether the probe was stopped at its deadline.
    public var timedOut: Bool
    /// The tmux client's exit status, when it exited.
    public var exitStatus: Int32?
    /// Bounded standard output.
    public var standardOutput: String
    /// Bounded standard error.
    public var standardError: String

    /// Creates a probe outcome.
    ///
    /// - Parameters:
    ///   - socketExists: Whether the socket path existed before probing.
    ///   - launched: Whether the tmux client started.
    ///   - timedOut: Whether the deadline stopped the client.
    ///   - exitStatus: Exit status of a client that exited.
    ///   - standardOutput: Captured standard output.
    ///   - standardError: Captured standard error.
    public init(
        socketExists: Bool,
        launched: Bool = true,
        timedOut: Bool = false,
        exitStatus: Int32? = nil,
        standardOutput: String = "",
        standardError: String = ""
    ) {
        self.socketExists = socketExists
        self.launched = launched
        self.timedOut = timedOut
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}
