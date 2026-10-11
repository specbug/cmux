/// Whether a persisted local-tmux binding can still reach its original session.
public enum LocalTmuxRestoreLiveness: Equatable, Sendable {
    /// The same server incarnation still hosts the same session; reattach.
    case live
    /// The server or session is provably gone (for example after a reboot).
    ///
    /// This state is permanent for a binding: the server marker is random per
    /// server process, so no later server can make the binding live again.
    case ended
    /// The probe could not decide. Callers keep the guarded attach command,
    /// which fails closed, rather than risk starting a second copy of work
    /// that may still be running.
    case unknown
}
