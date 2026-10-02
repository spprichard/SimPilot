import Foundation
import Logging
import Testing
import TypeSafe
@testable import SimPilotCore

@Suite struct DecisionTests {
    func context(textValues: [String: String] = [:], allowScroll: Bool = false) throws -> DecisionContext {
        let snapshot = try Fixture.snapshot("settings-root")
        return DecisionContext(
            goal: "Open General",
            app: "com.apple.Preferences",
            snapshot: snapshot,
            tapTargets: snapshot.targets(.tap),
            typeTargets: textValues.isEmpty ? [] : snapshot.targets(.type),
            textValues: textValues,
            allowScroll: allowScroll,
            recentActions: []
        )
    }

    @Test func offersOnlyUsableOperations() throws {
        #expect(try context().offeredOperations == [.tap, .wait, .done, .blocked])
        #expect(try context(textValues: ["q": "x"], allowScroll: true).offeredOperations == ActionKind.allCases)
    }

    @Test func sendsEveryHeadInOneRequest() async throws {
        let general = try #require(try context().tapTargets.first { $0.name == "General" })
        let transport = StubTransport(json: """
        {"model":"jev-1.13.0","answers":{
          "operation":{"type":"choice","choice":"TAP","confidence":0.97,"probabilities":{"TAP":0.97,"WAIT":0.01,"DONE":0.01,"BLOCKED":0.01}},
          "tap_target":{"type":"choice","choice":"\(general.id)","confidence":0.9,"probabilities":{"\(general.id)":0.9}}},
          "usage":{"input_tokens":500,"output_tokens":20}}
        """)
        let client = try TypeSafeClient(apiKey: "test", transport: transport, logger: Logger(label: "test"), environment: [:])

        let decision = try await JevDecider(client: client).decide(try context())

        #expect(decision.operation == .tap)
        #expect(decision.target?.name == "General")
        #expect(decision.probability == 0.9)
        #expect(decision.usage.inputTokens == 500)

        let body = try #require(await transport.bodies.first)
        let questions = try #require(body["questions"]?.objectValue)
        #expect(Array(questions.keys) == ["operation", "tap_target"])
        #expect(questions["tap_target"]?["criteria"]?[String(general.id)]?.stringValue == general.candidateText)
        #expect(body["state"]?["goal"]?.stringValue == "Open General")
    }

    @Test func typeTextReadsTargetAndValueHeads() throws {
        let context = try context(textValues: ["query": "Keyboard"])
        let field = try #require(context.typeTargets.first)
        let response = SystemOneResponse(
            model: "jev",
            answers: [
                "operation": .choice(ChoiceAnswer(choice: "TYPE_TEXT", probabilities: ["TYPE_TEXT": 0.8], confidence: 0.8)),
                "type_text_target": .choice(ChoiceAnswer(choice: String(field.id), probabilities: [String(field.id): 0.95], confidence: 0.95)),
                "text_value": .choice(ChoiceAnswer(choice: "query", probabilities: ["query": 0.7], confidence: 0.7)),
            ],
            usage: Usage(inputTokens: 1, outputTokens: 1)
        )

        let decision = try JevDecider.parse(response, context: context, latency: .zero)

        #expect(decision.target?.id == field.id)
        #expect(decision.textKey == "query")
        #expect(decision.probability == 0.7)
    }

    @Test func rejectsOperationThatWasNotOffered() throws {
        let response = SystemOneResponse(
            model: "jev",
            answers: ["operation": .choice(ChoiceAnswer(choice: "SCROLL_DOWN", probabilities: ["SCROLL_DOWN": 1], confidence: 1))],
            usage: Usage(inputTokens: 1, outputTokens: 1)
        )

        #expect(throws: DecisionError.self) {
            try JevDecider.parse(response, context: try context(), latency: .zero)
        }
    }
}
