public import Foundation

/// Recreates a local-tmux session whose server is gone and resumes its agent inside it.
///
/// Restore types this command into the fresh login shell of a terminal whose
/// local-tmux server incarnation is provably gone, in place of a plain
/// `cmux restore <kind> <id>`. The CLI then creates a replacement session,
/// rebinds the profile's registry record to it, and respawns the terminal
/// onto the new attach command, so the recovered conversation is persistent
/// again. The replacement's first pane waits for a client to attach before it
/// runs `cmux restore --surface <surface> <kind> <id>`, so the agent's first
/// hook can already be attributed to the terminal showing the session.
///
/// ```swift
/// let command = LocalTmuxRecoveryCommand(
///     serverID: binding.serverID, sessionID: binding.sessionID,
///     agentKind: "claude", checkpointID: sessionID
/// )
/// let input = command?.typedInput
/// ```
public struct LocalTmuxRecoveryCommand: Equatable, Sendable {
    /// The CLI subcommand path after `cmux`.
    public static let subcommand = ["local-tmux", "__recover"]

    /// Server incarnation marker of the session that is gone.
    public let serverID: UUID
    /// Immutable tmux session ID of the session that is gone, such as `$3`.
    public let sessionID: String
    /// Agent kind for `cmux restore`, such as `claude` or `codex`.
    public let agentKind: String
    /// Saved conversation to resume.
    public let checkpointID: String

    /// Creates a validated recovery command.
    ///
    /// - Parameters:
    ///   - serverID: Server marker from the persisted attach command.
    ///   - sessionID: `$N` session ID from the persisted attach command.
    ///   - agentKind: Kind passed to `cmux restore`.
    ///   - checkpointID: Conversation ID passed to `cmux restore`.
    /// - Returns: `nil` when any value is unsafe to type into a shell.
    public init?(serverID: UUID, sessionID: String, agentKind: String, checkpointID: String) {
        guard sessionID.range(of: "^\\$[0-9]+$", options: .regularExpression) != nil,
              AgentRestoreCLIArgument(rawValue: agentKind) != nil,
              AgentRestoreCLIArgument(rawValue: checkpointID) != nil else {
            return nil
        }
        self.serverID = serverID
        self.sessionID = sessionID
        self.agentKind = agentKind
        self.checkpointID = checkpointID
    }

    /// Parses the arguments that follow ``subcommand``.
    ///
    /// - Parameter arguments: `--server-id <uuid> --session-id <$N> --agent <kind> --checkpoint <id>`.
    /// - Returns: `nil` for a missing, repeated, unknown, or invalid argument.
    public init?(arguments: [String]) {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard ["--server-id", "--session-id", "--agent", "--checkpoint"].contains(flag),
                  values[flag] == nil,
                  index + 1 < arguments.count else {
                return nil
            }
            values[flag] = arguments[index + 1]
            index += 2
        }
        guard let rawServerID = values["--server-id"],
              let serverID = UUID(uuidString: rawServerID),
              let sessionID = values["--session-id"],
              let agentKind = values["--agent"],
              let checkpointID = values["--checkpoint"] else {
            return nil
        }
        self.init(serverID: serverID, sessionID: sessionID, agentKind: agentKind, checkpointID: checkpointID)
    }

    /// The arguments that follow ``subcommand``.
    public var arguments: [String] {
        [
            "--server-id", serverID.uuidString.lowercased(),
            "--session-id", sessionID,
            "--agent", agentKind,
            "--checkpoint", checkpointID,
        ]
    }

    /// Input typed into a fresh shell, with a leading space so shells that
    /// ignore space-prefixed commands keep it out of history.
    ///
    /// Every token is single-quoted; that spelling is a literal in POSIX
    /// shells, fish, and nushell alike.
    public var typedInput: String {
        let tokens = [AgentRestoreLaunch.cliStartupExecutableToken]
            + Self.subcommand.map(Self.singleQuoted)
            + arguments.map(Self.singleQuoted)
        return " " + tokens.joined(separator: " ") + "\n"
    }

    /// A tmux `wait-for` channel unique to one recovery attempt.
    ///
    /// - Parameter nonce: A fresh value per attempt.
    /// - Returns: The channel name.
    public static func attachChannel(nonce: UUID) -> String {
        "cmux-recover-\(nonce.uuidString.lowercased())"
    }

    /// tmux arguments, appended after `new-session`, that release the
    /// replacement pane when the first client attaches.
    ///
    /// Without `-t` the hook applies to the session just created in the
    /// same tmux command. tmux remembers a signal sent before anyone waits,
    /// so an early attach cannot be missed.
    ///
    /// - Parameter channel: The channel from ``attachChannel(nonce:)``.
    /// - Returns: Arguments starting with the `;` command separator.
    public static func attachHookArguments(channel: String) -> [String] {
        [";", "set-hook", "client-attached", "wait-for -S \(channel)"]
    }

    /// The `/bin/sh -lc` command for the replacement session's first pane.
    ///
    /// It waits for a client to attach, resumes the saved conversation for the
    /// terminal, and leaves a login shell in the pane whether or not the
    /// resume succeeded, so a failure stays visible and retryable.
    ///
    /// - Parameters:
    ///   - tmuxPath: The profile's tmux executable.
    ///   - socketPath: The profile's server socket.
    ///   - cliPath: The bundled cmux CLI.
    ///   - surfaceID: The terminal surface that owns the saved conversation.
    ///   - channel: The channel from ``attachChannel(nonce:)``.
    /// - Returns: A POSIX shell command.
    public func paneCommand(
        tmuxPath: String,
        socketPath: String,
        cliPath: String,
        surfaceID: UUID,
        channel: String
    ) -> String {
        let wait = [tmuxPath, "-S", socketPath, "wait-for", channel].map(Self.singleQuoted)
        let restore = [cliPath, "restore", "--surface", surfaceID.uuidString, agentKind, checkpointID]
            .map(Self.singleQuoted)
        return wait.joined(separator: " ") + "; "
            + restore.joined(separator: " ") + "; "
            + #"exec "${SHELL:-/bin/sh}" -l"#
    }

    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
