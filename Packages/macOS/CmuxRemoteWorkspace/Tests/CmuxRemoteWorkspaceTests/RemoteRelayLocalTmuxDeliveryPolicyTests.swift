import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// The local-tmux delivery probe maps a tmux session on this Mac to a local
/// surface. A remote relay must never reach it: its tmux identities belong to
/// another host, and the answer would reveal local surface ownership.
@Suite("Remote relay local-tmux delivery probe")
struct RemoteRelayLocalTmuxDeliveryPolicyTests {
    private let owner = UUID()

    private func parameters(includingLocalTmux: Bool) -> [String: Any] {
        var parameters: [String: Any] = [
            "workspace_id": owner.uuidString,
            "tty_name": "/dev/pts/3",
            "tty_resolution": "reported_tty",
        ]
        if includingLocalTmux {
            parameters["local_tmux_server_id"] = UUID().uuidString.lowercased()
            parameters["local_tmux_session_id"] = "$0"
        }
        return parameters
    }

    private func authorize(_ parameters: [String: Any]) -> RemoteRelayAuthorizationPolicy.Decision {
        var stamped = parameters
        stamped[RemoteRelayAuthorizationPolicy.remoteWorkspaceIDKey] = owner.uuidString
        return RemoteRelayAuthorizationPolicy().validate(
            method: "agent.resolve_delivery_target",
            parameters: stamped,
            ownerWorkspaceID: owner,
            surfaceIDs: []
        )
    }

    private func evaluate(_ parameters: [String: Any]) throws -> RemoteRelayCommandPolicy.Verdict {
        let request: [String: Any] = [
            "id": "probe", "method": "agent.resolve_delivery_target", "params": parameters,
        ]
        let line = try JSONSerialization.data(withJSONObject: request)
        return RemoteRelayCommandPolicy().evaluate(
            commandLine: line, workspaceAliases: [owner: owner], surfaceAliases: [:]
        )
    }

    @Test("the authenticated TTY probe remains allowed")
    func ttyProbeAllowed() throws {
        #expect(authorize(parameters(includingLocalTmux: false)) == .allowed)
        #expect(try evaluate(parameters(includingLocalTmux: false)) == .allow)
    }

    @Test("local-tmux identity parameters are denied by both relay gates")
    func localTmuxProbeDenied() throws {
        #expect(authorize(parameters(includingLocalTmux: true)) != .allowed)
        #expect(try evaluate(parameters(includingLocalTmux: true)) != .allow)
        let bare: [String: Any] = [
            "local_tmux_server_id": UUID().uuidString.lowercased(),
            "local_tmux_session_id": "$0",
        ]
        #expect(authorize(bare) != .allowed)
        #expect(try evaluate(bare) != .allow)
    }

    /// Recording a local-tmux attach command on a surface is local-only: a
    /// relay could otherwise point a local terminal's next restore at a
    /// session on this Mac.
    @Test("surface.local_tmux_adopt is denied by both relay gates")
    func adoptDenied() throws {
        let surface = UUID()
        var parameters: [String: Any] = [
            "workspace_id": owner.uuidString,
            "surface_id": surface.uuidString,
            "tmux_start_command": "/usr/bin/env TMUX= CMUX_LOCAL_TMUX=1 '/usr/bin/tmux' -S '/tmp/x/server.sock' if-shell -F 'c' 'a' 'run-shell false'",
        ]
        var stamped = parameters
        stamped[RemoteRelayAuthorizationPolicy.remoteWorkspaceIDKey] = owner.uuidString
        #expect(RemoteRelayAuthorizationPolicy().validate(
            method: "surface.local_tmux_adopt",
            parameters: stamped,
            ownerWorkspaceID: owner,
            surfaceIDs: [surface]
        ) != .allowed)
        parameters["surface_id"] = surface.uuidString
        let request: [String: Any] = ["id": "adopt", "method": "surface.local_tmux_adopt", "params": parameters]
        let line = try JSONSerialization.data(withJSONObject: request)
        #expect(RemoteRelayCommandPolicy().evaluate(
            commandLine: line, workspaceAliases: [owner: owner], surfaceAliases: [surface: surface]
        ) != .allow)
    }
}
