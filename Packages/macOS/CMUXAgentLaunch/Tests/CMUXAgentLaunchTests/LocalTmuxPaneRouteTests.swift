import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("LocalTmuxPaneRoute")
struct LocalTmuxPaneRouteTests {
    private let socket = "/Users/test/.cmux/local-tmux/server.sock"

    @Test("a pane on any tmux socket is recognized with its own socket")
    func recognizesPane() throws {
        let route = try #require(LocalTmuxPaneRoute(environment: [
            "TMUX": "/Users/test/custom-state/server.sock,4821,0",
            "TMUX_PANE": "%12",
            "CMUX_LOCAL_TMUX": "1",
        ]))
        #expect(route.paneID == "%12")
        #expect(route.socketPath == "/Users/test/custom-state/server.sock")
        #expect(route.carriesProfileMarker)
        #expect(!route.isOnSocket(socket))
        #expect(route.isOnSocket("/Users/test/custom-state/./server.sock"))
        #expect(route.displayArguments == [
            "-S", "/Users/test/custom-state/server.sock", "display-message", "-p", "-t", "%12",
            "#{session_id} #{@cmux_local_server_id}",
        ])
    }

    @Test("missing panes and malformed values are ignored")
    func ignoresMalformed() {
        let cases: [[String: String]] = [
            [:],
            ["TMUX": "\(socket),4821,0"],
            ["TMUX": "\(socket),4821,0", "TMUX_PANE": "%1; rm"],
            ["TMUX": "server.sock,1,0", "TMUX_PANE": "%1"],
            ["TMUX": socket, "TMUX_PANE": "%1"],
        ]
        for environment in cases {
            #expect(LocalTmuxPaneRoute(environment: environment) == nil)
        }
        let unmarked = LocalTmuxPaneRoute(environment: ["TMUX": "\(socket),1,0", "TMUX_PANE": "%1"])
        #expect(unmarked?.carriesProfileMarker == false)
    }

    @Test("socket paths containing commas keep their full value")
    func commaInSocketPath() {
        let commaSocket = "/Users/a,b/.cmux/local-tmux/server.sock"
        let route = LocalTmuxPaneRoute(environment: ["TMUX": "\(commaSocket),10,2", "TMUX_PANE": "%0"])
        #expect(route?.socketPath == commaSocket)
    }

    @Test("display output yields the session and server marker")
    func parsesIdentity() throws {
        let route = try #require(LocalTmuxPaneRoute(environment: ["TMUX": "\(socket),1,0", "TMUX_PANE": "%3"]))
        let marker = UUID()
        let identity = route.identity(fromDisplayOutput: "$7 \(marker.uuidString.lowercased())\n")
        #expect(identity == .init(serverID: marker, sessionID: "$7"))
        #expect(route.identity(fromDisplayOutput: "$7 \n") == nil)
        #expect(route.identity(fromDisplayOutput: "$7_\(marker.uuidString)") == nil)
        #expect(route.identity(fromDisplayOutput: "") == nil)
    }

    @Test("queued delivery keeps every key the route needs")
    func routingKeys() {
        #expect(Set(LocalTmuxPaneRoute.routingEnvironmentKeys).isSuperset(of: [
            "TMUX", "TMUX_PANE", "CMUX_LOCAL_TMUX", "CMUX_LOCAL_TMUX_STATE_DIR", "CMUX_LOCAL_TMUX_BIN",
        ]))
    }
}
