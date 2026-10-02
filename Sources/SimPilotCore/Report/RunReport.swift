import Foundation

public struct ActionRecord: Codable, Sendable {
    public var operation: ActionKind
    public var target: String?
    public var textKey: String?
    public var probability: Double
    public var latencyMs: Double
    public var screenChanged: Bool?
}

public struct StepResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Every expected label appeared.
        case passed
        /// Jev said DONE but the expected labels are missing.
        case unverified
        /// Jev said BLOCKED, confidence fell below the threshold, or foreign UI took over.
        case blocked
        /// Three actions in a row left the screen unchanged.
        case stuck
        /// Ran out of actions or model calls.
        case exhausted
        /// A tool or API error.
        case failed
    }

    public var goal: String
    public var status: Status
    public var reason: String?
    public var actions: [ActionRecord] = []
    public var modelCalls = 0
    public var staleDecisions = 0
    public var latenciesMs: [Double] = []
    public var inputTokens = 0
    public var outputTokens = 0
    public var durationMs: Double = 0
}

public struct RunReport: Codable, Sendable {
    public var plan: String
    public var udid: String
    public var steps: [StepResult]
    public var durationMs: Double

    public var passed: Bool { steps.allSatisfy { $0.status == .passed } }
    public var modelCalls: Int { steps.reduce(0) { $0 + $1.modelCalls } }
    public var inputTokens: Int { steps.reduce(0) { $0 + $1.inputTokens } }
    public var outputTokens: Int { steps.reduce(0) { $0 + $1.outputTokens } }

    public var medianLatencyMs: Double? {
        let sorted = steps.flatMap(\.latenciesMs).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
