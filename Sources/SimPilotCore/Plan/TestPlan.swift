import Foundation

/// A JSON test plan: an app to launch and an ordered list of goals, each verified by labels on screen.
public struct TestPlan: Codable, Sendable {
    public static let schemaID = "simpilot/plan/v1"

    public var schema: String
    public var name: String
    public var app: App
    public var defaults: Defaults?
    public var steps: [Step]

    public struct App: Codable, Sendable {
        public var bundleId: String
        public var relaunch: Bool?
    }

    public struct Defaults: Codable, Sendable {
        public var maxSteps: Int?
        public var minProbability: Double?
        public var allowScroll: Bool?
    }

    public struct Step: Codable, Sendable {
        public var goal: String
        /// Every label must be visible for the step to pass.
        public var expectLabels: [String]
        /// When set, Jev may only tap controls whose name contains one of these.
        public var allowLabels: [String]?
        /// Named text Jev may type. No text is generated.
        public var textValues: [String: String]?
        public var allowScroll: Bool?
        public var maxSteps: Int?
        public var minProbability: Double?
    }

    public static func load(from url: URL) throws -> TestPlan {
        let plan = try JSONDecoder().decode(TestPlan.self, from: Data(contentsOf: url))
        try plan.validate()
        return plan
    }

    public func validate() throws {
        guard schema == Self.schemaID else { throw SimPilotError.invalidPlan("schema must be \"\(Self.schemaID)\"") }
        guard !app.bundleId.isEmpty else { throw SimPilotError.invalidPlan("app.bundleId is empty") }
        guard !steps.isEmpty else { throw SimPilotError.invalidPlan("plan has no steps") }
        for (index, step) in steps.enumerated() {
            let where_ = "step \(index + 1)"
            let settings = resolved(step)
            guard !step.goal.trimmingCharacters(in: .whitespaces).isEmpty, step.goal.count <= 4000 else {
                throw SimPilotError.invalidPlan("\(where_): goal must be 1–4000 characters")
            }
            guard (1...30).contains(step.expectLabels.count) else {
                throw SimPilotError.invalidPlan("\(where_): expectLabels needs 1–30 labels")
            }
            guard (1...30).contains(settings.maxSteps) else {
                throw SimPilotError.invalidPlan("\(where_): maxSteps must be 1–30")
            }
            guard (0...1).contains(settings.minProbability) else {
                throw SimPilotError.invalidPlan("\(where_): minProbability must be 0–1")
            }
            guard (step.textValues?.count ?? 0) <= 20 else {
                throw SimPilotError.invalidPlan("\(where_): at most 20 textValues")
            }
        }
    }

    /// A step with plan defaults applied.
    public struct ResolvedStep: Sendable {
        public var goal: String
        public var expectLabels: [String]
        public var allowLabels: [String]?
        public var textValues: [String: String]
        public var allowScroll: Bool
        public var maxSteps: Int
        public var minProbability: Double
    }

    public func resolved(_ step: Step) -> ResolvedStep {
        ResolvedStep(
            goal: step.goal,
            expectLabels: step.expectLabels,
            allowLabels: step.allowLabels,
            textValues: step.textValues ?? [:],
            allowScroll: step.allowScroll ?? defaults?.allowScroll ?? false,
            maxSteps: step.maxSteps ?? defaults?.maxSteps ?? 12,
            minProbability: step.minProbability ?? defaults?.minProbability ?? 0.55
        )
    }
}
