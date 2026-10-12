import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("LocalTmuxRecoveryCommand")
struct LocalTmuxRecoveryCommandTests {
    private let serverID = UUID(uuidString: "6B1B7C55-9C55-4C55-8C55-6B1B7C559C55")!
    private let tmux = "/opt/homebrew/bin/tmux"
    private let socket = "/Users/a b/custom-state/server.sock"

    private func command(
        sessionID: String = "$1",
        agentKind: String = "claude",
        checkpointID: String = "x",
        tmuxPath: String? = nil,
        socketPath: String? = nil
    ) -> LocalTmuxRecoveryCommand? {
        LocalTmuxRecoveryCommand(
            tmuxPath: tmuxPath ?? tmux, socketPath: socketPath ?? socket,
            serverID: serverID, sessionID: sessionID, agentKind: agentKind, checkpointID: checkpointID
        )
    }

    @Test("typed input carries the original profile and round-trips through the CLI parser")
    func roundTrip() throws {
        let recovery = try #require(command(sessionID: "$12", checkpointID: "0b6f1c3e-7d4a-4e2b-9a1f-2c3d4e5f6a7b"))
        #expect(recovery.typedInput == " cmux 'local-tmux' '__recover' '--tmux' '/opt/homebrew/bin/tmux' '--socket' '/Users/a b/custom-state/server.sock' '--server-id' '6b1b7c55-9c55-4c55-8c55-6b1b7c559c55' '--session-id' '$12' '--agent' 'claude' '--checkpoint' '0b6f1c3e-7d4a-4e2b-9a1f-2c3d4e5f6a7b'\n")
        #expect(LocalTmuxRecoveryCommand(arguments: recovery.arguments) == recovery)
    }

    @Test("unsafe or incomplete values are rejected")
    func rejectsUnsafe() {
        #expect(command(sessionID: "work") == nil)
        #expect(command(agentKind: "claude; rm") == nil)
        #expect(command(checkpointID: "-x") == nil)
        #expect(command(tmuxPath: "tmux") == nil)
        #expect(command(tmuxPath: "/opt/it's/tmux") == nil)
        #expect(command(socketPath: "/tmp/other.sock") == nil)
        #expect(command(socketPath: "/tmp/a/../server.sock") == nil)
        #expect(command(socketPath: "/tmp/line\nbreak/server.sock") == nil)
        let complete = command()!.arguments
        #expect(LocalTmuxRecoveryCommand(arguments: Array(complete.dropLast(2))) == nil)
        #expect(LocalTmuxRecoveryCommand(arguments: complete + ["--checkpoint", "b"]) == nil)
        #expect(LocalTmuxRecoveryCommand(arguments: ["--bogus", "1"]) == nil)
    }

    @Test("the pane waits for an attach, resumes the exact conversation, then keeps a shell")
    func paneCommand() throws {
        let recovery = try #require(command(
            sessionID: "$0", agentKind: "codex", checkpointID: "019a-thread",
            socketPath: "/Users/a b/.cmux/local-tmux/server.sock"
        ))
        let surface = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let pane = recovery.paneCommand(
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
            tmuxPath: tmux, socketPath: socket,
            serverID: UUID(), sessionID: "$0", agentKind: "claude", checkpointID: "conversation-1"
        ))
        let surface = UUID()
        let channel = LocalTmuxRecoveryCommand.attachChannel(nonce: UUID())
        let pane = command.paneCommand(cliPath: fakeCLI.path, surfaceID: surface, channel: channel)
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
