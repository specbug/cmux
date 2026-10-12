import CmuxWorkspaces
import Foundation

@MainActor
extension TerminalController {
    /// `surface.local_tmux_adopt` — record that a terminal became the client of
    /// a recreated local-tmux session.
    ///
    /// Cold recovery cannot respawn the terminal: respawning discards the
    /// restore record and agent checkpoint that the replacement session's
    /// `cmux restore --surface` needs. Instead the recovering process becomes
    /// the tmux client and reports the new attach command here, so snapshots
    /// and hook attribution follow the replacement session.
    ///
    /// Only a cmux-generated local-tmux attach command is accepted, and only
    /// through the local socket; the relay routing schema has no entry for
    /// this method.
    func v2SurfaceLocalTmuxAdopt(params: [String: Any]) -> V2CallResult {
        let policy = Workspace.makeSessionRestorePolicyService()
        guard params["_cmux_remote_workspace_id"] == nil,
              let surfaceID = v2UUID(params, "surface_id"),
              let command = params["tmux_start_command"] as? String,
              policy.localTmuxStartCommand(command) == command,
              policy.localTmuxRestoreBinding(command) != nil else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "surface.localTmuxAdopt.error.invalidParams",
                    defaultValue: "surface_id and a cmux-generated local-tmux attach command are required"
                ),
                data: nil
            )
        }
        guard let appDelegate = AppDelegate.shared,
              let terminal = appDelegate.liveTerminalPanel(
                  surfaceID: surfaceID,
                  preferredWorkspaceID: v2UUID(params, "workspace_id")
              ),
              !terminal.surface.isRemoteTerminal else {
            return .err(
                code: "not_found",
                message: String(
                    localized: "surface.localTmuxAdopt.error.notFound",
                    defaultValue: "No local terminal surface with that ID"
                ),
                data: nil
            )
        }
        terminal.surface.adoptLocalPersistentAttachCommand(command)
        return .ok(["surface_id": surfaceID.uuidString])
    }
}
