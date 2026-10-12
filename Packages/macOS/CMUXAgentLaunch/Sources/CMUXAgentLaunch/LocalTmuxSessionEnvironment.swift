import Foundation

/// The cmux agent-integration variables a local-tmux session's panes receive.
///
/// The local-tmux server starts from a sanitized environment, so without these
/// variables an agent inside the session neither loads cmux's wrapper nor
/// reports hooks, and cmux can never save a resumable checkpoint for it. The
/// set is an explicit allowlist: the control socket path, bundled CLI, agent
/// wrapper shims, the cmux surface identity, and the profile's state
/// directory and tmux selectors, plus ``markerKey``. Socket passwords and any
/// other inherited `CMUX_*` state are excluded.
///
/// Identity values describe the surface that created the session and are only
/// hints: the session can later be shown in another surface, and tmux cannot
/// change the environment of processes that are already running. cmux attributes agent hooks inside the profile
/// server by tmux session identity instead (``LocalTmuxPaneRoute``).
public struct LocalTmuxSessionEnvironment: Equatable, Sendable {
    private static let exactKeys: Set<String> = [
        "CMUX_SURFACE_ID",
        "CMUX_PANEL_ID",
        "CMUX_WORKSPACE_ID",
        "CMUX_TAB_ID",
        "CMUX_SOCKET_PATH",
        "CMUX_BUNDLED_CLI_PATH",
        "CMUX_CLAUDE_INTEGRATION_DISABLED",
        "CMUX_AGENT_COMMAND_SHIM_ROOT",
        // Profile selectors: hooks and `cmux local-tmux` inside the session
        // must address the same state directory and tmux client.
        "CMUX_LOCAL_TMUX_STATE_DIR",
        "CMUX_LOCAL_TMUX_BIN",
    ]
    private static let maximumValueBytes = 4096

    /// Marks panes of sessions the local-tmux profile created.
    ///
    /// Its value is always `1`. It lets a hook skip tmux queries for panes of
    /// unrelated tmux servers; ownership is still decided by the server marker.
    public static let markerKey = "CMUX_LOCAL_TMUX"

    /// Selected variables, sorted by name.
    public let variables: [(key: String, value: String)]

    /// Selects the integration variables from a caller environment.
    ///
    /// The surface/panel and workspace/tab aliases are completed from each
    /// other so a pane never carries only half of an identity pair.
    ///
    /// - Parameter environment: The environment of the `cmux local-tmux` caller.
    public init(environment: [String: String]) {
        var selected: [String: String] = [:]
        for (key, value) in environment where Self.isIntegrationKey(key) && Self.isSafeValue(value) {
            selected[key] = value
        }
        for (primary, alias) in [("CMUX_SURFACE_ID", "CMUX_PANEL_ID"), ("CMUX_WORKSPACE_ID", "CMUX_TAB_ID")] {
            if let value = selected[primary] ?? selected[alias] {
                selected[primary] = value
                selected[alias] = value
            }
        }
        selected[Self.markerKey] = "1"
        variables = selected.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Compares the selected names and values in order.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.variables.map(\.key) == rhs.variables.map(\.key)
            && lhs.variables.map(\.value) == rhs.variables.map(\.value)
    }

    /// `new-session` arguments that set each variable for the new session.
    public var newSessionArguments: [String] {
        variables.flatMap { ["-e", "\($0.key)=\($0.value)"] }
    }

    static func isIntegrationKey(_ key: String) -> Bool {
        if exactKeys.contains(key) { return true }
        return key.range(
            of: "^CMUX_[A-Z0-9_]+_WRAPPER_SHIM(_ROOT)?$",
            options: .regularExpression
        ) != nil
    }

    private static func isSafeValue(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumValueBytes
            && !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}
