import Testing
@testable import CMUXAgentLaunch

@Suite("LocalTmuxSessionEnvironment")
struct LocalTmuxSessionEnvironmentTests {
    @Test("only integration variables are passed, never socket secrets")
    func allowlist() {
        let selected = LocalTmuxSessionEnvironment(environment: [
            "CMUX_SURFACE_ID": "11111111-1111-4111-8111-111111111111",
            "CMUX_WORKSPACE_ID": "22222222-2222-4222-8222-222222222222",
            "CMUX_SOCKET_PATH": "/Users/test/Library/Application Support/cmux/cmux.sock",
            "CMUX_SOCKET_PASSWORD": "secret",
            "CMUX_BUNDLED_CLI_PATH": "/Applications/cmux.app/Contents/Resources/bin/cmux",
            "CMUX_CLAUDE_WRAPPER_SHIM": "/Users/test/.cmux/shims/s/claude",
            "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": "/Users/test/.cmux/shims/s",
            "CMUX_TERMINAL_LIFECYCLE_ID": "lifecycle",
            "CMUX_HISTORY_FILE": "/tmp/history",
            "CLAUDE_CONFIG_DIR": "/Users/test/.claude-work",
            "CMUX_LOCAL_TMUX_STATE_DIR": "/Users/test/custom-state",
            "PATH": "/usr/bin",
        ])
        #expect(selected.variables.map(\.key) == [
            "CMUX_BUNDLED_CLI_PATH",
            "CMUX_CLAUDE_WRAPPER_SHIM",
            "CMUX_CLAUDE_WRAPPER_SHIM_ROOT",
            "CMUX_LOCAL_TMUX",
            "CMUX_LOCAL_TMUX_STATE_DIR",
            "CMUX_PANEL_ID",
            "CMUX_SOCKET_PATH",
            "CMUX_SURFACE_ID",
            "CMUX_TAB_ID",
            "CMUX_WORKSPACE_ID",
        ])
        #expect(selected.newSessionArguments.contains("-e"))
        #expect(!selected.newSessionArguments.contains { $0.contains("secret") })
    }

    @Test("identity aliases are completed from either name")
    func aliases() {
        let selected = LocalTmuxSessionEnvironment(environment: [
            "CMUX_PANEL_ID": "panel",
            "CMUX_TAB_ID": "tab",
        ])
        let values = Dictionary(uniqueKeysWithValues: selected.variables.map { ($0.key, $0.value) })
        #expect(values == [
            "CMUX_LOCAL_TMUX": "1",
            "CMUX_SURFACE_ID": "panel",
            "CMUX_PANEL_ID": "panel",
            "CMUX_WORKSPACE_ID": "tab",
            "CMUX_TAB_ID": "tab",
        ])
    }

    @Test("empty, multi-line, or oversized values are dropped")
    func unsafeValues() {
        let selected = LocalTmuxSessionEnvironment(environment: [
            "CMUX_SURFACE_ID": "",
            "CMUX_SOCKET_PATH": "/tmp/a\n/tmp/b",
            "CMUX_BUNDLED_CLI_PATH": String(repeating: "a", count: 5000),
        ])
        #expect(selected.variables.map(\.key) == ["CMUX_LOCAL_TMUX"])
        #expect(selected.newSessionArguments == ["-e", "CMUX_LOCAL_TMUX=1"])
    }
}
