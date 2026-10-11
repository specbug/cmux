import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("LocalTmuxRestoreLiveness")
struct LocalTmuxRestoreLivenessTests {
    private let serverID = UUID(uuidString: "6B1B7C55-9C55-4C55-8C55-6B1B7C559C55")!
    private let otherServerID = UUID(uuidString: "0D0D0D0D-1E1E-4F4F-8A8A-2B2B2B2B2B2B")!

    private func binding(
        sessionID: String = "$0",
        serverID: UUID? = nil,
        socket: String = "/tmp/cmux-test/server.sock"
    ) -> LocalTmuxRestoreBinding {
        LocalTmuxRestoreBinding(
            tmuxPath: "/usr/bin/tmux",
            socketPath: socket,
            serverID: serverID ?? self.serverID,
            sessionID: sessionID
        )
    }

    private func classify(
        _ binding: LocalTmuxRestoreBinding,
        _ outcome: LocalTmuxServerProbeOutcome
    ) -> LocalTmuxRestoreLiveness? {
        LocalTmuxRestoreLivenessClassifier().classify([binding], outcome: outcome)[binding]
    }

    @Test("a missing socket means the server ended")
    func missingSocketEnded() {
        #expect(classify(binding(), .init(socketExists: false, launched: false)) == .ended)
    }

    @Test("tmux reporting no listening server means ended, including a stale socket")
    func noServerEnded() {
        let noServer = LocalTmuxServerProbeOutcome(
            socketExists: true,
            exitStatus: 1,
            standardError: "no server running on /tmp/cmux-test/server.sock\n"
        )
        #expect(classify(binding(), noServer) == .ended)
        let refused = LocalTmuxServerProbeOutcome(
            socketExists: true,
            exitStatus: 1,
            standardError: "error connecting to /tmp/cmux-test/server.sock (Connection refused)\n"
        )
        #expect(classify(binding(), refused) == .ended)
    }

    @Test("inconclusive failures stay unknown so the guarded attach is kept")
    func inconclusiveUnknown() {
        let denied = LocalTmuxServerProbeOutcome(
            socketExists: true,
            exitStatus: 1,
            standardError: "error connecting to /tmp/cmux-test/server.sock (Permission denied)\n"
        )
        #expect(classify(binding(), denied) == .unknown)
        #expect(classify(binding(), .init(socketExists: true, timedOut: true)) == .unknown)
        #expect(classify(binding(), .init(socketExists: true, launched: false)) == .unknown)
        let malformed = LocalTmuxServerProbeOutcome(
            socketExists: true,
            exitStatus: 0,
            standardOutput: "work not-a-row\n"
        )
        #expect(classify(binding(), malformed) == .unknown)
    }

    @Test("the same server incarnation and session is live")
    func matchingSessionLive() {
        let outcome = LocalTmuxServerProbeOutcome(
            socketExists: true,
            exitStatus: 0,
            standardOutput: "$0 \(serverID.uuidString.lowercased())\n$4 \(serverID.uuidString.lowercased())\n"
        )
        #expect(classify(binding(sessionID: "$4"), outcome) == .live)
        #expect(classify(binding(sessionID: "$2"), outcome) == .ended)
    }

    @Test("a restarted server that reuses the session ID is not the same session")
    func reusedSessionIDOnNewServerEnded() {
        let outcome = LocalTmuxServerProbeOutcome(
            socketExists: true,
            exitStatus: 0,
            standardOutput: "$0 \(otherServerID.uuidString.lowercased())\n"
        )
        #expect(classify(binding(), outcome) == .ended)
        let unmanaged = LocalTmuxServerProbeOutcome(socketExists: true, exitStatus: 0, standardOutput: "$0 \n")
        #expect(classify(binding(), unmanaged) == .ended)
    }

    @Test("each endpoint is probed once and bindings are classified independently")
    func probeGroupsByEndpoint() {
        final class Calls: @unchecked Sendable { var arguments: [[String]] = [] }
        let calls = Calls()
        let live = binding(sessionID: "$1")
        let gone = binding(sessionID: "$2")
        let elsewhere = binding(socket: "/tmp/cmux-other/server.sock")
        let probe = LocalTmuxRestoreLivenessProbe(
            socketExists: { $0 == "/tmp/cmux-test/server.sock" },
            runner: { _, arguments, _ in
                calls.arguments.append(arguments)
                return LocalTmuxServerProbeOutcome(
                    socketExists: false,
                    exitStatus: 0,
                    standardOutput: "$1 \(UUID(uuidString: "6B1B7C55-9C55-4C55-8C55-6B1B7C559C55")!.uuidString.lowercased())\n"
                )
            }
        )
        let result = probe.probe([live, gone, elsewhere])
        #expect(result[live] == .live)
        #expect(result[gone] == .ended)
        #expect(result[elsewhere] == .ended)
        #expect(calls.arguments == [[
            "-S", "/tmp/cmux-test/server.sock", "list-sessions", "-F",
            "#{session_id} #{@cmux_local_server_id}",
        ]])
    }

    /// A socket the user cannot reach is not evidence that its server died.
    /// Recording `ended` would be permanent for the app process and would
    /// abandon the attach path for a server that may still be running.
    @Test(
        "an unreadable socket directory stays unknown",
        .enabled(if: geteuid() != 0, "root bypasses directory permissions")
    )
    func unreadableSocketDirectoryUnknown() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-lt-acl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let locked = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let target = LocalTmuxRestoreBinding(
            tmuxPath: RealTmux.executable ?? "/usr/bin/tmux",
            socketPath: locked.appendingPathComponent("server.sock").path,
            serverID: serverID,
            sessionID: "$0"
        )
        #expect(LocalTmuxRestoreLivenessProbe().probe([target])[target] == .unknown)
    }

    @Test("an ended decision is permanent and unprobed bindings are unknown")
    func ledgerKeepsEnded() {
        let ledger = LocalTmuxRestoreLivenessLedger()
        let target = binding()
        #expect(ledger.liveness(for: target) == .unknown)
        ledger.record([target: .ended])
        ledger.record([target: .live])
        #expect(ledger.liveness(for: target) == .ended)
        let other = binding(sessionID: "$9")
        ledger.record([other: .live])
        ledger.record([other: .unknown])
        #expect(ledger.liveness(for: other) == .unknown)
    }
}

/// Exercises the probe against a real tmux server when one is installed.
///
/// The cases mirror what a reboot and a server restart leave behind: a socket
/// file whose server was killed without cleanup, and a new server on the same
/// socket whose first session reuses `$0`.
@Suite("LocalTmuxRestoreLiveness real tmux", .enabled(if: RealTmux.executable != nil))
struct LocalTmuxRestoreLivenessRealTmuxTests {
    @Test("live, killed, and restarted servers are classified from real tmux output")
    func realServerLifecycle() throws {
        let tmux = try #require(RealTmux.executable)
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-lt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("server.sock").path
        let first = UUID()
        try RealTmux.startServer(tmux: tmux, socket: socket, marker: first)
        let firstBinding = LocalTmuxRestoreBinding(
            tmuxPath: tmux, socketPath: socket, serverID: first, sessionID: "$0"
        )
        let probe = LocalTmuxRestoreLivenessProbe()
        #expect(probe.probe([firstBinding])[firstBinding] == .live)

        // A reboot or crash kills the server without removing its socket.
        try RealTmux.killServerProcess(tmux: tmux, socket: socket)
        #expect(FileManager.default.fileExists(atPath: socket))
        #expect(probe.probe([firstBinding])[firstBinding] == .ended)

        // A later server on the same socket reuses `$0` with a new marker.
        let second = UUID()
        try RealTmux.startServer(tmux: tmux, socket: socket, marker: second)
        defer { RealTmux.run(tmux, ["-S", socket, "kill-server"]) }
        let secondBinding = LocalTmuxRestoreBinding(
            tmuxPath: tmux, socketPath: socket, serverID: second, sessionID: "$0"
        )
        let restarted = probe.probe([firstBinding, secondBinding])
        #expect(restarted[firstBinding] == .ended)
        #expect(restarted[secondBinding] == .live)
    }
}

enum RealTmux {
    static let executable: String? = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = path.split(separator: ":").map { "\($0)/tmux" }
            + ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Runs a tmux client. A command that starts a server must not capture
    /// output: the forked server would inherit the pipe and hold it open.
    @discardableResult
    static func run(
        _ tmux: String,
        _ arguments: [String],
        captureOutput: Bool = true
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = arguments
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

    static func startServer(tmux: String, socket: String, marker: UUID) throws {
        let arguments = [
            "-f", "/dev/null", "-S", socket,
            "new-session", "-d", "-s", "work", "sleep 600",
            ";", "set-option", "-s", "@cmux_local_server_id", marker.uuidString.lowercased(),
        ]
#if os(Linux)
        // swift-corelibs-foundation observes child exit through a descriptor
        // the child inherits; the daemonized server would keep it open and
        // stall `waitUntilExit`. Close inherited descriptors before exec.
        let started = run("/bin/bash", [
            "-c",
            #"for fd in /proc/$$/fd/*; do n=${fd##*/}; [ "$n" -gt 2 ] && eval "exec $n>&-"; done; exec "$0" "$@""#,
            tmux,
        ] + arguments, captureOutput: false)
#else
        let started = run(tmux, arguments, captureOutput: false)
#endif
        try #require(started.status == 0, "tmux failed to start (status \(started.status))")
    }

    static func killServerProcess(tmux: String, socket: String) throws {
        let pid = run(tmux, ["-S", socket, "display-message", "-p", "#{pid}"])
        let serverPID = try #require(Int32(pid.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        kill(serverPID, SIGKILL)
        for _ in 0..<100 where kill(serverPID, 0) == 0 {
            usleep(20_000)
        }
    }
}
