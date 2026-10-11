import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("LocalTmuxPaneRoute")
struct LocalTmuxPaneRouteTests {
    private let socket = "/Users/test/.cmux/local-tmux/server.sock"

    @Test("a pane inside the profile server is recognized")
    func recognizesProfilePane() throws {
        let route = try #require(LocalTmuxPaneRoute(
            environment: ["TMUX": "\(socket),4821,0", "TMUX_PANE": "%12"],
            profileSocketPath: socket
        ))
        #expect(route.paneID == "%12")
        #expect(route.displayArguments == [
            "-S", socket, "display-message", "-p", "-t", "%12",
            "#{session_id} #{@cmux_local_server_id}",
        ])
    }

    @Test("other tmux servers, missing panes, and malformed values are ignored")
    func ignoresOtherServers() {
        let cases: [[String: String]] = [
            [:],
            ["TMUX": "/private/tmp/tmux-501/default,99,0", "TMUX_PANE": "%1"],
            ["TMUX": "\(socket),4821,0"],
            ["TMUX": "\(socket),4821,0", "TMUX_PANE": "%1; rm"],
            ["TMUX": "server.sock,1,0", "TMUX_PANE": "%1"],
            ["TMUX": socket, "TMUX_PANE": "%1"],
        ]
        for environment in cases {
            #expect(LocalTmuxPaneRoute(environment: environment, profileSocketPath: socket) == nil)
        }
    }

    @Test("socket paths containing commas keep their full value")
    func commaInSocketPath() {
        let commaSocket = "/Users/a,b/.cmux/local-tmux/server.sock"
        #expect(LocalTmuxPaneRoute(
            environment: ["TMUX": "\(commaSocket),10,2", "TMUX_PANE": "%0"],
            profileSocketPath: commaSocket
        ) != nil)
    }

    @Test("display output yields the session and server marker")
    func parsesIdentity() throws {
        let route = try #require(LocalTmuxPaneRoute(
            environment: ["TMUX": "\(socket),1,0", "TMUX_PANE": "%3"],
            profileSocketPath: socket
        ))
        let marker = UUID()
        let identity = route.identity(fromDisplayOutput: "$7 \(marker.uuidString.lowercased())\n")
        #expect(identity == .init(serverID: marker, sessionID: "$7"))
        #expect(route.identity(fromDisplayOutput: "$7 \n") == nil)
        #expect(route.identity(fromDisplayOutput: "$7_\(marker.uuidString)") == nil)
        #expect(route.identity(fromDisplayOutput: "") == nil)
    }
}
