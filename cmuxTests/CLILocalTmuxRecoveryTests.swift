import CMUXAgentLaunch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import XCTest

/// Cold recovery of a local-tmux session against a real tmux server.
///
/// Each test seeds a registry record for a session, kills its server the way a
/// reboot does (leaving the socket behind), and then recovers it with the same
/// planner `cmux local-tmux __recover` uses. The replacement server is started
/// first so the planner adds a session to it; on Linux, Foundation cannot wait
/// for a client that forks the tmux server itself.
final class CLILocalTmuxRecoveryTests: XCTestCase {
    private var root: URL!
    private var tmux: String!
    private var registry: LocalTmuxSessionRegistry!
    private var builder: LocalTmuxCommandBuilder!
    private var runner: LocalTmuxProcessRunner!

    override func setUpWithError() throws {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = path.split(separator: ":").map { "\($0)/tmux" }
            + ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let tmux = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("tmux is not installed")
        }
        self.tmux = tmux
        // A custom profile directory, never ~/.cmux/local-tmux.
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-rt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        registry = LocalTmuxSessionRegistry(rootURL: root)
        try registry.ensureSecureStorage()
        builder = LocalTmuxCommandBuilder(tmuxPath: tmux, socketPath: registry.serverSocketURL.path)
        runner = LocalTmuxProcessRunner(executablePath: tmux)
    }

    override func tearDown() {
        if let tmux, let registry {
            Self.tmuxCommand(tmux, ["-S", registry.serverSocketURL.path, "kill-server"])
        }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testTerminalsOfOneDeadSessionConvergeOnOneReplacement() throws {
        let (record, recovery) = try seedDeadSession(named: "work")
        let planner = LocalTmuxSessionRecovery(registry: registry, builder: builder, runner: runner)

        let first = try planner.prepare(
            recovery, surfaceID: UUID(), cliPath: "/bin/true", environment: [:], workingDirectory: root.path
        )
        let second = try planner.prepare(
            recovery, surfaceID: UUID(), cliPath: "/bin/true", environment: [:], workingDirectory: root.path
        )

        XCTAssertTrue(first.created)
        XCTAssertFalse(second.created, "a second terminal created another replacement")
        XCTAssertEqual(second.binding, first.binding)
        let records = try registry.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, record.id, "the logical record was replaced")
        XCTAssertEqual(records.first?.name, "work")
        XCTAssertEqual(records.first?.tmuxBinding, first.binding)
        XCTAssertEqual(
            records.first?.recoveredFrom,
            [.init(serverID: recovery.serverID, sessionID: recovery.sessionID)]
        )
    }

    func testConcurrentRecoveriesCreateOneReplacement() throws {
        let (_, recovery) = try seedDeadSession(named: "work")
        let attempts = ConcurrentAttempts(
            planner: LocalTmuxSessionRecovery(registry: registry, builder: builder, runner: runner),
            recovery: recovery,
            workingDirectory: root.path
        )
        DispatchQueue.concurrentPerform(iterations: 3) { _ in attempts.run() }
        XCTAssertTrue(attempts.failures.isEmpty, "\(attempts.failures)")
        XCTAssertEqual(attempts.results.filter(\.created).count, 1)
        XCTAssertEqual(Set(attempts.results.map(\.binding)).count, 1)
        XCTAssertEqual(try sessionNames(), ["keep", "work"])
    }

    /// Collects concurrent recovery attempts; every access holds `lock`.
    private final class ConcurrentAttempts: @unchecked Sendable {
        let planner: LocalTmuxSessionRecovery
        let recovery: LocalTmuxRecoveryCommand
        let workingDirectory: String
        private let lock = NSLock()
        private(set) var results: [LocalTmuxSessionRecovery.Prepared] = []
        private(set) var failures: [String] = []

        init(planner: LocalTmuxSessionRecovery, recovery: LocalTmuxRecoveryCommand, workingDirectory: String) {
            self.planner = planner
            self.recovery = recovery
            self.workingDirectory = workingDirectory
        }

        func run() {
            do {
                let prepared = try planner.prepare(
                    recovery, surfaceID: UUID(), cliPath: "/bin/true", environment: [:],
                    workingDirectory: workingDirectory
                )
                lock.lock(); results.append(prepared); lock.unlock()
            } catch {
                lock.lock(); failures.append(String(describing: error)); lock.unlock()
            }
        }
    }

    func testRecoveryNeverAdoptsALiveSessionThatReusesTheName() throws {
        let (_, recovery) = try seedDeadSession(named: "work")
        // Someone started an unrelated session with the old name.
        Self.tmuxCommand(tmux, ["-S", registry.serverSocketURL.path, "new-session", "-d", "-s", "work", "sleep 600"])
        let unrelated = try LocalTmuxSessionIdentityResolver(registry: registry, builder: builder, runner: runner)
            .observedSession(named: "work").binding

        let prepared = try LocalTmuxSessionRecovery(registry: registry, builder: builder, runner: runner).prepare(
            recovery, surfaceID: UUID(), cliPath: "/bin/true", environment: [:], workingDirectory: root.path
        )

        XCTAssertTrue(prepared.created)
        XCTAssertNotEqual(prepared.binding, unrelated)
        XCTAssertTrue(prepared.record.name.hasPrefix("work-"), prepared.record.name)
        XCTAssertTrue(try sessionNames().contains("work"), "the unrelated session was disturbed")
        // A later terminal of the same dead session finds the renamed replacement.
        let again = try LocalTmuxSessionRecovery(registry: registry, builder: builder, runner: runner).prepare(
            recovery, surfaceID: UUID(), cliPath: "/bin/true", environment: [:], workingDirectory: root.path
        )
        XCTAssertFalse(again.created)
        XCTAssertEqual(again.binding, prepared.binding)
    }

    func testReplacementKeepsTheOriginalProfileAndWaitsForAnAttach() throws {
        let (_, recovery) = try seedDeadSession(named: "work")
        let prepared = try LocalTmuxSessionRecovery(registry: registry, builder: builder, runner: runner).prepare(
            recovery,
            surfaceID: UUID(),
            cliPath: "/bin/true",
            environment: ["CMUX_SURFACE_ID": "11111111-1111-4111-8111-111111111111", "CMUX_SOCKET_PASSWORD": "secret"],
            workingDirectory: root.path
        )
        XCTAssertEqual(prepared.record.socketPath, registry.serverSocketURL.path)
        let environment = Self.tmuxCommand(tmux, [
            "-S", registry.serverSocketURL.path, "show-environment", "-t", prepared.binding.sessionID.rawValue,
        ]).output
        XCTAssertTrue(environment.contains("CMUX_LOCAL_TMUX_STATE_DIR=\(root.path)\n"), environment)
        XCTAssertTrue(environment.contains("CMUX_LOCAL_TMUX_BIN=\(tmux!)\n"), environment)
        XCTAssertTrue(environment.contains("CMUX_LOCAL_TMUX=1\n"), environment)
        XCTAssertFalse(environment.contains("secret"))
        let hooks = Self.tmuxCommand(tmux, [
            "-S", registry.serverSocketURL.path, "show-hooks", "-t", prepared.binding.sessionID.rawValue,
        ]).output
        XCTAssertTrue(hooks.contains("client-attached[0] wait-for -S cmux-recover-"), hooks)
    }

    // MARK: - Fixture

    /// Creates a registered session, kills its server without cleanup, and
    /// starts a fresh server on the same socket.
    private func seedDeadSession(
        named name: String
    ) throws -> (LocalTmuxSessionRecord, LocalTmuxRecoveryCommand) {
        let socket = registry.serverSocketURL.path
        Self.tmuxCommand(tmux, ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", name, "sleep 600"])
        let resolver = LocalTmuxSessionIdentityResolver(registry: registry, builder: builder, runner: runner)
        let observed = try resolver.observedSession(named: name)
        let record = LocalTmuxSessionRecord(
            name: name, tmuxBinding: observed.binding, socketPath: socket, cwd: root.path
        )
        try registry.upsert(record)

        let pid = Self.tmuxCommand(tmux, ["-S", socket, "display-message", "-p", "#{pid}"]).output
        let serverPID = try XCTUnwrap(Int32(pid.trimmingCharacters(in: .whitespacesAndNewlines)))
        kill(serverPID, SIGKILL)
        for _ in 0..<100 where kill(serverPID, 0) == 0 { usleep(20_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "a reboot leaves the socket behind")

        Self.tmuxCommand(tmux, ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "keep", "sleep 600"])
        let recovery = try XCTUnwrap(LocalTmuxRecoveryCommand(
            tmuxPath: tmux,
            socketPath: socket,
            serverID: observed.binding.serverID,
            sessionID: observed.binding.sessionID.rawValue,
            agentKind: "claude",
            checkpointID: "conversation-1"
        ))
        return (record, recovery)
    }

    private func sessionNames() throws -> [String] {
        Self.tmuxCommand(tmux, ["-S", registry.serverSocketURL.path, "list-sessions", "-F", "#{session_name}"])
            .output.split(separator: "\n").map(String.init).sorted()
            .map { $0.hasPrefix("work-") ? "work-*" : $0 }
    }

    /// Runs tmux without capturing a forked server's descriptors.
    @discardableResult
    private static func tmuxCommand(_ tmux: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
#if os(Linux)
        // swift-corelibs-foundation observes child exit through an inherited
        // descriptor that a daemonized tmux server would keep open.
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            #"for fd in /proc/$$/fd/*; do n=${fd##*/}; [ "$n" -gt 2 ] && eval "exec $n>&-"; done; exec "$0" "$@" > "$CMUX_TMUX_TEST_OUT" 2>&1"#,
            tmux,
        ] + arguments
#else
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = arguments
#endif
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tmux-out-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX")
        environment["CMUX_TMUX_TEST_OUT"] = output.path
        process.environment = environment
        let handle = try? FileHandle(forWritingTo: output)
#if !os(Linux)
        process.standardOutput = handle
        process.standardError = handle
#else
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
#endif
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        process.waitUntilExit()
        try? handle?.close()
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        return (process.terminationStatus, text)
    }
}
