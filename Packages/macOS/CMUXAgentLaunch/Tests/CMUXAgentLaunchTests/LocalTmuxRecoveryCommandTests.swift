import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("LocalTmuxRecoveryCommand")
struct LocalTmuxRecoveryCommandTests {
    private let serverID = UUID(uuidString: "6B1B7C55-9C55-4C55-8C55-6B1B7C559C55")!

    @Test("typed input round-trips through the CLI parser")
    func roundTrip() throws {
        let command = try #require(LocalTmuxRecoveryCommand(
            serverID: serverID, sessionID: "$12", agentKind: "claude", checkpointID: "0b6f1c3e-7d4a-4e2b-9a1f-2c3d4e5f6a7b"
        ))
        #expect(command.typedInput == " cmux 'local-tmux' '__recover' '--server-id' '6b1b7c55-9c55-4c55-8c55-6b1b7c559c55' '--session-id' '$12' '--agent' 'claude' '--checkpoint' '0b6f1c3e-7d4a-4e2b-9a1f-2c3d4e5f6a7b'\n")
        #expect(LocalTmuxRecoveryCommand(arguments: command.arguments) == command)
    }

    @Test("unsafe or incomplete values are rejected")
    func rejectsUnsafe() {
        #expect(LocalTmuxRecoveryCommand(serverID: serverID, sessionID: "work", agentKind: "claude", checkpointID: "x") == nil)
        #expect(LocalTmuxRecoveryCommand(serverID: serverID, sessionID: "$1", agentKind: "claude; rm", checkpointID: "x") == nil)
        #expect(LocalTmuxRecoveryCommand(serverID: serverID, sessionID: "$1", agentKind: "codex", checkpointID: "-x") == nil)
        #expect(LocalTmuxRecoveryCommand(arguments: ["--server-id", serverID.uuidString, "--session-id", "$1", "--agent", "codex"]) == nil)
        #expect(LocalTmuxRecoveryCommand(arguments: [
            "--server-id", serverID.uuidString, "--session-id", "$1", "--agent", "codex",
            "--checkpoint", "a", "--checkpoint", "b",
        ]) == nil)
        #expect(LocalTmuxRecoveryCommand(arguments: ["--bogus", "1"]) == nil)
    }

    @Test("the pane waits for an attach, resumes the exact conversation, then keeps a shell")
    func paneCommand() throws {
        let command = try #require(LocalTmuxRecoveryCommand(
            serverID: serverID, sessionID: "$0", agentKind: "codex", checkpointID: "019a-thread"
        ))
        let surface = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let pane = command.paneCommand(
            tmuxPath: "/opt/homebrew/bin/tmux",
            socketPath: "/Users/a b/.cmux/local-tmux/server.sock",
            cliPath: "/Applications/cmux.app/Contents/Resources/bin/cmux",
            surfaceID: surface,
            channel: "cmux-recover-x"
        )
        #expect(pane == "'/opt/homebrew/bin/tmux' '-S' '/Users/a b/.cmux/local-tmux/server.sock' 'wait-for' 'cmux-recover-x'; '/Applications/cmux.app/Contents/Resources/bin/cmux' 'restore' '--surface' '11111111-2222-4333-8444-555555555555' 'codex' '019a-thread'; exec \"${SHELL:-/bin/sh}\" -l")
        #expect(LocalTmuxRecoveryCommand.attachHookArguments(channel: "cmux-recover-x")
            == [";", "set-hook", "client-attached", "wait-for -S cmux-recover-x"])
    }
}

/// Runs the replacement-session shape against real tmux: the first pane must
/// not start the resume before a client attaches, and must start it after.
@Suite("LocalTmuxRecoveryCommand real tmux", .enabled(if: RecoveryTmux.executable != nil))
struct LocalTmuxRecoveryCommandRealTmuxTests {
    @Test("the replacement pane resumes only after a client attaches")
    func gatedOnAttach() throws {
        let tmux = try #require(RecoveryTmux.executable)
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("cmux-rc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            RecoveryTmux.run(tmux, ["-S", directory.appendingPathComponent("server.sock").path, "kill-server"])
            try? FileManager.default.removeItem(at: directory)
        }
        let socket = directory.appendingPathComponent("server.sock").path
        let log = directory.appendingPathComponent("calls")
        let fakeCLI = directory.appendingPathComponent("cmux")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\n".write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)
        let command = try #require(LocalTmuxRecoveryCommand(
            serverID: UUID(), sessionID: "$0", agentKind: "claude", checkpointID: "conversation-1"
        ))
        let surface = UUID()
        let channel = LocalTmuxRecoveryCommand.attachChannel(nonce: UUID())
        let pane = command.paneCommand(
            tmuxPath: tmux, socketPath: socket, cliPath: fakeCLI.path, surfaceID: surface, channel: channel
        )
        let created = RecoveryTmux.run(tmux, [
            "-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "work", "/bin/sh", "-lc", pane,
        ] + LocalTmuxRecoveryCommand.attachHookArguments(channel: channel), captureOutput: false)
        try #require(created.status == 0)
        usleep(300_000)
        #expect(!FileManager.default.fileExists(atPath: log.path), "resume ran before any client attached")

        // The hook is what a real attach runs; fire it the way tmux does.
        RecoveryTmux.run(tmux, ["-S", socket, "wait-for", "-S", channel])
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: log.path) { usleep(20_000) }
        let calls = try String(contentsOf: log, encoding: .utf8)
        #expect(calls == "restore --surface \(surface.uuidString) claude conversation-1\n")
        let hooks = RecoveryTmux.run(tmux, ["-S", socket, "show-hooks", "-t", "work"]).output
        #expect(hooks.contains("client-attached[0] wait-for -S \(channel)"))
    }
}

enum RecoveryTmux {
    static let executable: String? = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = path.split(separator: ":").map { "\($0)/tmux" }
            + ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Runs tmux. A command that starts a server must not capture output: the
    /// forked server would inherit the pipe and hold it open.
    @discardableResult
    static func run(_ tmux: String, _ arguments: [String], captureOutput: Bool = true) -> (status: Int32, output: String) {
        let process = Process()
#if os(Linux)
        // swift-corelibs-foundation observes child exit through an inherited
        // descriptor that a daemonized server would keep open.
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            #"for fd in /proc/$$/fd/*; do n=${fd##*/}; [ "$n" -gt 2 ] && eval "exec $n>&-"; done; exec "$0" "$@""#,
            tmux,
        ] + arguments
#else
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = arguments
#endif
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = captureOutput ? output : FileHandle.nullDevice
        process.standardError = captureOutput ? output : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = captureOutput ? output.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
