import Foundation
import Logging

/// Runs one plan step: observe → decide → re-check → act, until the expected labels appear
/// or a stop condition is hit.
public struct StepRunner: Sendable {
    public var device: any DeviceDriver
    public var decider: any Decider
    public var app: String
    /// The launched app's pid; UI from any other process (e.g. a system alert) blocks the step.
    public var expectedPID: Int32?
    public var settleDelay: Duration
    public var logger: Logger

    static let stuckLimit = 3

    public init(
        device: any DeviceDriver, decider: any Decider, app: String, expectedPID: Int32?,
        settleDelay: Duration = .milliseconds(500), logger: Logger = Logger(label: "simpilot")
    ) {
        self.device = device
        self.decider = decider
        self.app = app
        self.expectedPID = expectedPID
        self.settleDelay = settleDelay
        self.logger = logger
    }

    public func run(_ step: TestPlan.ResolvedStep) async -> StepResult {
        let clock = ContinuousClock()
        let start = clock.now
        var result = StepResult(goal: step.goal, status: .failed)
        do {
            try await loop(step, into: &result)
        } catch {
            result.status = .failed
            result.reason = "\(error)"
        }
        result.durationMs = (clock.now - start).milliseconds
        return result
    }

    private func loop(_ step: TestPlan.ResolvedStep, into result: inout StepResult) async throws {
        var recentActions: [String] = []
        var unchangedActions = 0
        var fingerprintBeforeAction: String?

        while true {
            let snapshot = try await observe()

            if let before = fingerprintBeforeAction, let last = result.actions.indices.last {
                let changed = snapshot.fingerprint != before
                result.actions[last].screenChanged = changed
                recentActions[recentActions.count - 1] += changed ? " → screen changed" : " → no change"
                unchangedActions = changed ? 0 : unchangedActions + 1
                fingerprintBeforeAction = nil
            }

            if let expectedPID, let pid = snapshot.pid, pid != expectedPID {
                return finish(&result, .blocked, "UI belongs to another process (pid \(pid)); a system alert may be showing")
            }
            let missing = step.expectLabels.filter { !snapshot.contains(label: $0) }
            if missing.isEmpty {
                return finish(&result, .passed, nil)
            }
            if unchangedActions >= Self.stuckLimit {
                return finish(&result, .stuck, "\(Self.stuckLimit) actions without a screen change; missing \(missing)")
            }
            if result.actions.count >= step.maxSteps || result.modelCalls >= step.maxSteps * 2 {
                return finish(&result, .exhausted, "used \(result.actions.count) actions / \(result.modelCalls) model calls; missing \(missing)")
            }

            let context = DecisionContext(
                goal: step.goal,
                app: app,
                snapshot: snapshot,
                tapTargets: snapshot.targets(.tap, allowLabels: step.allowLabels),
                typeTargets: step.textValues.isEmpty ? [] : snapshot.targets(.type),
                textValues: step.textValues,
                allowScroll: step.allowScroll,
                recentActions: Array(recentActions.suffix(8))
            )
            let decision = try await decider.decide(context)
            result.modelCalls += 1
            result.latenciesMs.append(decision.latency.milliseconds)
            result.inputTokens += decision.usage.inputTokens
            result.outputTokens += decision.usage.outputTokens
            logger.info("\(describe(decision)) p=\(String(format: "%.2f", decision.probability)) \(Int(decision.latency.milliseconds))ms")

            if decision.probability < step.minProbability {
                return finish(&result, .blocked, "low confidence \(String(format: "%.2f", decision.probability)) for \(describe(decision))")
            }

            switch decision.operation {
            case .done:
                return finish(&result, .unverified, "Jev said DONE but \(missing) are not on screen")
            case .blocked:
                return finish(&result, .blocked, "Jev said BLOCKED")
            case .wait:
                try await Task.sleep(for: .milliseconds(300))
                continue
            case .tap, .typeText, .scrollUp, .scrollDown:
                break
            }

            // The decision was made against `snapshot`; act only if the screen still matches it.
            let fresh = try await observe()
            if fresh.fingerprint != snapshot.fingerprint {
                result.staleDecisions += 1
                logger.debug("screen changed while deciding; discarding decision")
                continue
            }

            try await perform(decision, step: step)
            result.actions.append(ActionRecord(
                operation: decision.operation,
                target: decision.target?.candidateText,
                textKey: decision.textKey,
                probability: decision.probability,
                latencyMs: decision.latency.milliseconds
            ))
            recentActions.append(describe(decision))
            fingerprintBeforeAction = snapshot.fingerprint
            try await Task.sleep(for: settleDelay)
        }
    }

    private func perform(_ decision: Decision, step: TestPlan.ResolvedStep) async throws {
        switch decision.operation {
        case .tap:
            guard let target = decision.target else { return }
            try await device.tap(x: target.frame.midX, y: target.frame.midY)
        case .typeText:
            guard let target = decision.target, let key = decision.textKey, let text = step.textValues[key] else { return }
            try await device.tap(x: target.frame.midX, y: target.frame.midY)
            try await Task.sleep(for: settleDelay)
            // Fields can move when focused (e.g. a toolbar search field expanding); confirm it is still there.
            let focused = try await observe()
            guard focused.targets(.type).contains(where: { $0.name == target.name || ($0.uniqueID != nil && $0.uniqueID == target.uniqueID) }) else {
                throw DecisionError(description: "text field \(target.candidateText) disappeared after tapping it")
            }
            try await device.type(text)
        case .scrollDown:
            try await device.scroll(.down)
        case .scrollUp:
            try await device.scroll(.up)
        case .wait, .done, .blocked:
            break
        }
    }

    private func observe() async throws -> Snapshot {
        Snapshot(elements: try await device.describeUI())
    }

    private func describe(_ decision: Decision) -> String {
        var text = decision.operation.rawValue
        if let target = decision.target { text += " \(target.candidateText)" }
        if let key = decision.textKey { text += " ← \(key)" }
        return text
    }

    private func finish(_ result: inout StepResult, _ status: StepResult.Status, _ reason: String?) {
        result.status = status
        result.reason = reason
    }
}
