/// How a restored terminal should treat its persisted local persistence command.
///
/// Local-tmux and local-zellij surfaces persist an attach command. While the
/// durable owner may still be running, that command stays authoritative and
/// agent metadata is not used. Once the owner is provably gone, the terminal
/// falls back to the ordinary restore path, where a saved agent checkpoint can
/// resume the exact conversation in a new process.
public enum LocalPersistentSessionRestore: Equatable, Sendable {
    /// The terminal has no cmux-generated local persistence command.
    case none
    /// Attach with this validated command; the owner may still be running.
    case attach(command: String)
    /// The local-tmux server or session that owned this terminal no longer exists.
    case ended(LocalTmuxRestoreBinding)

    /// The validated attach command, when attaching is still authoritative.
    public var attachCommand: String? {
        if case .attach(let command) = self { return command }
        return nil
    }

    /// Whether the durable owner is provably gone.
    public var hasEnded: Bool {
        if case .ended = self { return true }
        return false
    }
}
