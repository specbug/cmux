public import Foundation

/// Identifies the cmux local-tmux session that hosts an agent hook's pane.
///
/// An agent inside tmux does not run on its cmux surface's PTY, so a hook
/// cannot be attributed by controlling terminal. Its inherited `CMUX_*`
/// variables are not evidence either: they describe whichever surface created
/// the tmux session, and a session outlives or moves between client surfaces.
/// The pane's tmux session ID and the server's incarnation marker do identify
/// it, and the app can match that pair against the attach command of the
/// surface currently showing the session.
///
/// ```swift
/// if let route = LocalTmuxPaneRoute(environment: env, profileSocketPath: socket) {
///     let output = run(tmux, route.displayArguments)
///     let identity = route.identity(fromDisplayOutput: output)
/// }
/// ```
public struct LocalTmuxPaneRoute: Equatable, Sendable {
    /// Session identity read from the pane's tmux server.
    public struct Identity: Equatable, Sendable {
        /// Server incarnation marker (`@cmux_local_server_id`).
        public let serverID: UUID
        /// Immutable tmux session ID, such as `$3`.
        public let sessionID: String
    }

    /// The profile server socket the pane belongs to.
    public let socketPath: String
    /// The tmux pane ID, such as `%5`.
    public let paneID: String

    /// Recognizes a process environment inside the local-tmux profile server.
    ///
    /// - Parameters:
    ///   - environment: The hook process environment, inherited from the agent.
    ///   - profileSocketPath: The local-tmux profile's server socket.
    /// - Returns: `nil` outside tmux, inside another tmux server, or when the
    ///   variables are malformed.
    public init?(environment: [String: String], profileSocketPath: String) {
        guard let tmux = environment["TMUX"],
              let pane = environment["TMUX_PANE"],
              pane.range(of: "^%[0-9]+$", options: .regularExpression) != nil else {
            return nil
        }
        // `TMUX` is `<socket>,<server pid>,<session index>`; the socket path
        // itself may contain commas, so drop exactly the last two fields.
        var fields = tmux.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }
        fields.removeLast(2)
        let socket = fields.joined(separator: ",")
        guard socket.hasPrefix("/"),
              Self.standardized(socket) == Self.standardized(profileSocketPath) else {
            return nil
        }
        self.socketPath = profileSocketPath
        self.paneID = pane
    }

    /// Arguments that read the pane's session ID and server marker.
    ///
    /// Fields are space separated because tmux replaces control characters,
    /// including tabs, in formatted output when no UTF-8 locale is set.
    public var displayArguments: [String] {
        [
            "-S", socketPath, "display-message", "-p", "-t", paneID,
            "#{session_id} #{@cmux_local_server_id}",
        ]
    }

    /// Parses the output of ``displayArguments``.
    ///
    /// - Parameter output: The tmux client's standard output.
    /// - Returns: The identity, or `nil` for a server without a cmux marker.
    public func identity(fromDisplayOutput output: String) -> Identity? {
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2,
              fields[0].range(of: "^\\$[0-9]+$", options: .regularExpression) != nil,
              let serverID = UUID(uuidString: String(fields[1])) else {
            return nil
        }
        return Identity(serverID: serverID, sessionID: String(fields[0]))
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
