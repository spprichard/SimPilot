import Foundation
import TypeSafe

/// What Jev may do next. Raw values are the option names sent to the model.
public enum ActionKind: String, CaseIterable, Sendable, Codable {
    case tap = "TAP"
    case typeText = "TYPE_TEXT"
    case scrollDown = "SCROLL_DOWN"
    case scrollUp = "SCROLL_UP"
    case wait = "WAIT"
    case done = "DONE"
    case blocked = "BLOCKED"

    var meaning: String {
        switch self {
        case .tap: "Tap one of the tap targets to make progress toward the goal."
        case .typeText: "Type one of the provided text values into an empty text field the goal needs filled."
        case .scrollDown: "Scroll down because the control the goal needs is not visible yet."
        case .scrollUp: "Scroll up because the control the goal needs is above the visible area."
        case .wait: "The screen is still loading or animating; wait briefly and look again."
        case .done: "Every requirement of the goal is visibly satisfied on the current screen."
        case .blocked: "The goal cannot be reached from this screen with the available actions."
        }
    }
}

/// Everything the model sees for one decision.
public struct DecisionContext: Sendable {
    public var goal: String
    public var app: String
    public var snapshot: Snapshot
    public var tapTargets: [Control]
    public var typeTargets: [Control]
    public var textValues: [String: String]
    public var allowScroll: Bool
    public var recentActions: [String]

    public var offeredOperations: [ActionKind] {
        ActionKind.allCases.filter { operation in
            switch operation {
            case .tap: !tapTargets.isEmpty
            case .typeText: !typeTargets.isEmpty && !textValues.isEmpty
            case .scrollUp, .scrollDown: allowScroll
            case .wait, .done, .blocked: true
            }
        }
    }
}

public struct Decision: Sendable {
    public var operation: ActionKind
    public var target: Control?
    public var textKey: String?
    /// Lowest chosen-option probability across the heads that were used.
    public var probability: Double
    public var latency: Duration
    public var usage: Usage
    public var requestID: String?
}

public protocol Decider: Sendable {
    func decide(_ context: DecisionContext) async throws -> Decision
}

public struct DecisionError: Error, CustomStringConvertible {
    public var description: String
}

/// Asks Jev for the next action with one `systemOne` request.
///
/// The request carries every head at once — `operation`, `tap_target`, `type_text_target`,
/// `text_value` — and only the head matching the chosen operation is read, so one network
/// round trip yields a complete action.
public struct JevDecider: Decider {
    let client: TypeSafeClient
    let model: String?

    public init(client: TypeSafeClient, model: String? = nil) {
        self.client = client
        self.model = model
    }

    static let rules: JSONValue = [
        "Choose only from the options offered.",
        "Pick DONE only when the goal is visibly complete on the current screen.",
        "Prefer the most direct control whose name matches the goal.",
        "A back button is usually named after the previous screen.",
    ]

    public static func questions(for context: DecisionContext) -> Questions {
        var questions: Questions = [:]
        var operations: JSONObject = [:]
        for operation in context.offeredOperations {
            operations[operation.rawValue] = .string(operation.meaning)
        }
        questions["operation"] = .choice(["goal": .string(context.goal), "rules": rules], criteria: operations)

        if context.offeredOperations.contains(.tap) {
            questions["tap_target"] = .choice(
                "Which control should be tapped next to make progress toward the goal: \(context.goal)",
                criteria: criteria(for: context.tapTargets)
            )
        }
        if context.offeredOperations.contains(.typeText) {
            questions["type_text_target"] = .choice(
                "Which text field should receive text for the goal: \(context.goal)",
                criteria: criteria(for: context.typeTargets)
            )
            var values: JSONObject = [:]
            for key in context.textValues.keys.sorted() {
                values[key] = .string(context.textValues[key]!)
            }
            questions["text_value"] = .choice("Which provided value should be typed for the goal: \(context.goal)", criteria: values)
        }
        return questions
    }

    public static func state(for context: DecisionContext) -> JSONValue {
        [
            "goal": .string(context.goal),
            "app": .string(context.app),
            "screen": .array(context.snapshot.controls.filter { !$0.occluded }.map { .string($0.candidateText) }),
            "recent_actions": .array(context.recentActions.map { .string($0) }),
        ]
    }

    static func criteria(for controls: [Control]) -> JSONObject {
        var criteria: JSONObject = [:]
        for control in controls {
            criteria[String(control.id)] = .string(control.candidateText)
        }
        return criteria
    }

    public func decide(_ context: DecisionContext) async throws -> Decision {
        let clock = ContinuousClock()
        let start = clock.now
        let response = try await client.systemOne(
            state: Self.state(for: context),
            questions: Self.questions(for: context),
            model: model
        )
        let latency = clock.now - start
        return try Self.parse(response, context: context, latency: latency)
    }

    public static func parse(_ response: SystemOneResponse, context: DecisionContext, latency: Duration) throws -> Decision {
        let operationAnswer = try response.choice("operation")
        guard let operation = operationAnswer.choice(as: ActionKind.self), context.offeredOperations.contains(operation) else {
            throw DecisionError(description: "Jev chose an operation that was not offered: \(operationAnswer.choice)")
        }
        var probability = chosenProbability(operationAnswer)
        var target: Control?
        var textKey: String?

        func control(from head: String, in candidates: [Control]) throws -> Control {
            let answer = try response.choice(head)
            probability = min(probability, chosenProbability(answer))
            guard let id = Int(answer.choice), let control = candidates.first(where: { $0.id == id }) else {
                throw DecisionError(description: "Jev chose \(head) \(answer.choice), which was not offered")
            }
            return control
        }

        switch operation {
        case .tap:
            target = try control(from: "tap_target", in: context.tapTargets)
        case .typeText:
            target = try control(from: "type_text_target", in: context.typeTargets)
            let answer = try response.choice("text_value")
            probability = min(probability, chosenProbability(answer))
            guard context.textValues[answer.choice] != nil else {
                throw DecisionError(description: "Jev chose text value \(answer.choice), which was not offered")
            }
            textKey = answer.choice
        case .scrollUp, .scrollDown, .wait, .done, .blocked:
            break
        }

        return Decision(
            operation: operation,
            target: target,
            textKey: textKey,
            probability: probability,
            latency: latency,
            usage: response.usage,
            requestID: response.requestID
        )
    }

    static func chosenProbability(_ answer: ChoiceAnswer) -> Double {
        answer.probabilities[answer.choice] ?? answer.confidence
    }
}
