import Foundation

/// Explains, in a restored terminal, that its local-tmux session is gone.
///
/// Restore reaches this only when the tmux server incarnation that owned the
/// terminal is provably gone and no agent resume runs in the new shell. A bare
/// prompt would look like a successful reattach, so the pane says what
/// happened and, when a saved conversation exists, how to resume it.
struct LocalTmuxSessionEndedNotice: Sendable {
    /// Whether the terminal still carries a saved agent conversation.
    let hasAgentCheckpoint: Bool

    func startupInput(dialect: TerminalStartupShellDialect) -> String {
        AgentRestoreNoticeInput(message: message).startupInput(dialect: dialect)
    }

    var message: String {
        if hasAgentCheckpoint {
            return String(
                localized: "localTmux.restore.ended.checkpoint.notice",
                defaultValue: "This terminal's local-tmux session is no longer running (for example, after a restart), so cmux started a new shell. Its saved agent conversation was not resumed automatically; run 'cmux restore --surface' to resume it here."
            )
        }
        return String(
            localized: "localTmux.restore.ended.notice",
            defaultValue: "This terminal's local-tmux session is no longer running (for example, after a restart), so cmux started a new shell. No agent conversation was saved for this terminal, so nothing was resumed."
        )
    }
}
