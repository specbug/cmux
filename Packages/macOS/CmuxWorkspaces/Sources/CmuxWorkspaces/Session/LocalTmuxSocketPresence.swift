/// What the filesystem says about a tmux socket path before probing it.
public enum LocalTmuxSocketPresence: Equatable, Sendable {
    /// An entry exists at the path; only tmux can say whether a server listens.
    case present
    /// The path or one of its parent directories does not exist, so no server
    /// can be listening there and the attach command cannot reach one.
    case absent
    /// The entry could not be inspected (for example a permission error).
    /// This is not evidence about the server and must stay undecided.
    case inaccessible
}
