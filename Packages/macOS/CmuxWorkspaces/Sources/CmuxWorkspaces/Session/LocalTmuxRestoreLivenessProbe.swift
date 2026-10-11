public import Foundation

/// Probes local-tmux servers to classify persisted bindings before restore.
///
/// Each distinct tmux executable and socket is queried once with
/// `list-sessions`, which never starts a server. The probe blocks the calling
/// thread for at most `timeout` per endpoint, so callers run it off the main
/// actor and hand the result to ``LocalTmuxRestoreLivenessLedger``.
///
/// ```swift
/// let results = LocalTmuxRestoreLivenessProbe().probe(bindings)
/// ledger.record(results)
/// ```
public struct LocalTmuxRestoreLivenessProbe: Sendable {
    /// Runs one tmux client invocation and reports how it finished.
    public typealias Runner = @Sendable (
        _ executablePath: String,
        _ arguments: [String],
        _ timeout: TimeInterval
    ) -> LocalTmuxServerProbeOutcome

    private let timeout: TimeInterval
    private let socketExists: @Sendable (String) -> Bool
    private let runner: Runner
    private let classifier = LocalTmuxRestoreLivenessClassifier()

    /// Creates a probe.
    ///
    /// - Parameters:
    ///   - timeout: Deadline per server endpoint. Two seconds bounds startup
    ///     delay while comfortably covering a loaded but healthy server.
    ///   - socketExists: Reports whether any filesystem entry exists at a
    ///     socket path without following a final symbolic link.
    ///   - runner: Executes the tmux client; tests inject recorded outcomes.
    public init(
        timeout: TimeInterval = 2,
        socketExists: @escaping @Sendable (String) -> Bool = LocalTmuxRestoreLivenessProbe.pathEntryExists,
        runner: @escaping Runner = LocalTmuxRestoreLivenessProbe.runProcess
    ) {
        self.timeout = timeout
        self.socketExists = socketExists
        self.runner = runner
    }

    /// Classifies bindings, querying each server endpoint once.
    ///
    /// - Parameter bindings: Bindings collected from a session snapshot.
    /// - Returns: A liveness decision for every input binding.
    public func probe(
        _ bindings: Set<LocalTmuxRestoreBinding>
    ) -> [LocalTmuxRestoreBinding: LocalTmuxRestoreLiveness] {
        let byEndpoint = Dictionary(grouping: bindings, by: \.endpoint)
        var result: [LocalTmuxRestoreBinding: LocalTmuxRestoreLiveness] = [:]
        for (endpoint, endpointBindings) in byEndpoint {
            var outcome: LocalTmuxServerProbeOutcome
            if socketExists(endpoint.socketPath) {
                outcome = runner(endpoint.tmuxPath, endpoint.listSessionsArguments, timeout)
                outcome.socketExists = true
            } else {
                outcome = LocalTmuxServerProbeOutcome(socketExists: false, launched: false)
            }
            result.merge(classifier.classify(Set(endpointBindings), outcome: outcome)) { _, new in new }
        }
        return result
    }

    /// Reports whether a directory entry exists at `path`, including a dangling link.
    ///
    /// - Parameter path: Socket path to inspect.
    /// - Returns: `true` when `lstat(2)` finds an entry.
    @Sendable
    public static func pathEntryExists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    /// Runs a tmux client without inherited tmux client state and with a deadline.
    ///
    /// - Parameters:
    ///   - executablePath: Absolute tmux executable.
    ///   - arguments: Client arguments.
    ///   - timeout: Seconds before the client is terminated.
    /// - Returns: The bounded outcome; `socketExists` is filled by the caller.
    @Sendable
    public static func runProcess(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> LocalTmuxServerProbeOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // A probe issued from inside another tmux must still address only the
        // explicit `-S` socket.
        environment.removeValue(forKey: "TMUX")
        environment.removeValue(forKey: "TMUX_PANE")
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return LocalTmuxServerProbeOutcome(socketExists: true, launched: false)
        }
        let outputReader = BoundedPipeReader(pipe: output)
        let errorReader = BoundedPipeReader(pipe: error)
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
        }
        return LocalTmuxServerProbeOutcome(
            socketExists: true,
            launched: true,
            timedOut: timedOut,
            exitStatus: timedOut || process.isRunning ? nil : process.terminationStatus,
            standardOutput: outputReader.finish(),
            standardError: errorReader.finish()
        )
    }
}
