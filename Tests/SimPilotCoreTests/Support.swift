import Foundation
import Testing
import TypeSafe
@testable import SimPilotCore

enum Fixture {
    /// Real `axe describe-ui` output captured from the iOS 26.5 Settings app (iPhone 17 Pro).
    static func elements(_ name: String) throws -> [AXElement] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([AXElement].self, from: Data(contentsOf: url))
    }

    static func snapshot(_ name: String) throws -> Snapshot {
        Snapshot(elements: try elements(name))
    }
}

/// A transport that returns one canned response and records the request body.
actor StubTransport: HTTPTransport {
    private(set) var bodies: [JSONValue] = []
    let json: String

    init(json: String) {
        self.json = json
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if let body = request.body {
            bodies.append(try JSONDecoder().decode(JSONValue.self, from: body))
        }
        return HTTPResponse(status: 200, body: Data(json.utf8))
    }
}

/// A simulator that moves between canned screens when a named control is tapped.
actor FakeDevice: DeviceDriver {
    var screen: String
    /// Current screen → (tapped control name → next screen).
    let transitions: [String: [String: String]]
    let screens: [String: [AXElement]]
    let pid: Int32
    private(set) var taps: [String] = []
    private(set) var typed: [String] = []

    init(start: String, screens: [String: [AXElement]], transitions: [String: [String: String]], pid: Int32) {
        self.screen = start
        self.screens = screens
        self.transitions = transitions
        self.pid = pid
    }

    func describeUI() async throws -> [AXElement] {
        screens[screen] ?? []
    }

    func tap(x: Double, y: Double) async throws {
        let snapshot = Snapshot(elements: screens[screen] ?? [])
        let hit = snapshot.targets(.tap).last { $0.frame.contains(x: x, y: y) }
        taps.append(hit?.name ?? "nothing")
        if let name = hit?.name, let next = transitions[screen]?[name] {
            screen = next
        }
    }

    func type(_ text: String) async throws {
        typed.append(text)
    }

    func scroll(_ direction: ScrollDirection) async throws {}

    func launch(bundleID: String, relaunch: Bool) async throws -> Int32 { pid }
}

/// Replays scripted decisions, resolving target names against the live context.
actor ScriptedDecider: Decider {
    private var script: [(ActionKind, String?)]
    private(set) var contexts: [DecisionContext] = []

    init(_ script: [(ActionKind, String?)]) {
        self.script = script
    }

    func decide(_ context: DecisionContext) async throws -> Decision {
        contexts.append(context)
        guard !script.isEmpty else { return decision(.blocked, nil) }
        let (operation, name) = script.removeFirst()
        let pool = operation == .typeText ? context.typeTargets : context.tapTargets
        let target = name.flatMap { name in pool.first { $0.name == name } }
        return decision(operation, target, textKey: operation == .typeText ? context.textValues.keys.first : nil)
    }

    private func decision(_ operation: ActionKind, _ target: Control?, textKey: String? = nil) -> Decision {
        Decision(
            operation: operation, target: target, textKey: textKey, probability: 0.9,
            latency: .milliseconds(100), usage: Usage(inputTokens: 100, outputTokens: 10)
        )
    }
}
