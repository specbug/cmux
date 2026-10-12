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
/// if let route = LocalTmuxPaneRoute(environment: env) {
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

    /// Environment keys a hook must keep to be routed by tmux identity.
    ///
    /// Queued hook delivery stores only an allowlist of the hook process
    /// environment; these keys must be part of it.
    public static let routingEnvironmentKeys = [
        "TMUX", "TMUX_PANE",
        LocalTmuxSessionEnvironment.markerKey,
        "CMUX_LOCAL_TMUX_STATE_DIR", "CMUX_LOCAL_TMUX_BIN",
    ]

    /// The tmux server socket the pane belongs to, from `TMUX`.
    public let socketPath: String
    /// The tmux pane ID, such as `%5`.
    public let paneID: String
    /// Whether the pane's session was created by the cmux local-tmux profile.
    ///
    /// This is an inherited hint used only to decide whether asking tmux is
    /// worthwhile; ownership is decided by the server's own marker.
    public let carriesProfileMarker: Bool

    /// Recognizes a process environment inside any tmux pane.
    ///
    /// - Parameter environment: The hook process environment, inherited from the agent.
    /// - Returns: `nil` outside tmux or when the variables are malformed.
    public init?(environment: [String: String]) {
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
        guard socket.hasPrefix("/") else { return nil }
        self.socketPath = socket
        self.paneID = pane
        self.carriesProfileMarker = environment[LocalTmuxSessionEnvironment.markerKey] == "1"
    }

    /// Whether the pane's server listens on `path`.
    ///
    /// - Parameter path: A socket path, such as the default profile socket.
    /// - Returns: `true` when both paths standardize to the same file path.
    public func isOnSocket(_ path: String) -> Bool {
        Self.standardized(socketPath) == Self.standardized(path)
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
