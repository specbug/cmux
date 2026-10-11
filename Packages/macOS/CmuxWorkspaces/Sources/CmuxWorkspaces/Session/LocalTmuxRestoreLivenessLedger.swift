import Foundation

/// Thread-safe record of local-tmux liveness decisions for this app process.
///
/// The app target owns one ledger, fills it from an off-main
/// ``LocalTmuxRestoreLivenessProbe`` before startup restore, and injects
/// ``liveness(for:)`` into the restore policy. Unprobed bindings read as
/// ``LocalTmuxRestoreLiveness/unknown``. An ``LocalTmuxRestoreLiveness/ended``
/// decision is never overwritten because a server marker cannot come back.
public final class LocalTmuxRestoreLivenessLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [LocalTmuxRestoreBinding: LocalTmuxRestoreLiveness] = [:]

    /// Creates an empty ledger.
    public init() {}

    /// Records probe results.
    ///
    /// - Parameter results: Decisions keyed by binding.
    public func record(_ results: [LocalTmuxRestoreBinding: LocalTmuxRestoreLiveness]) {
        lock.lock()
        defer { lock.unlock() }
        for (binding, liveness) in results where states[binding] != .ended {
            states[binding] = liveness
        }
    }

    /// Returns the recorded decision for a binding.
    ///
    /// - Parameter binding: A binding parsed from a persisted attach command.
    /// - Returns: The decision, or ``LocalTmuxRestoreLiveness/unknown`` when unprobed.
    public func liveness(for binding: LocalTmuxRestoreBinding) -> LocalTmuxRestoreLiveness {
        lock.lock()
        defer { lock.unlock() }
        return states[binding] ?? .unknown
    }
}
