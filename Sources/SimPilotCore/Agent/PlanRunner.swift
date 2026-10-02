import Foundation
import Logging

/// Launches the plan's app and runs its steps in order, stopping at the first step that does not pass.
public struct PlanRunner: Sendable {
    public var device: any DeviceDriver
    public var decider: any Decider
    public var udid: String
    public var settleDelay: Duration
    public var logger: Logger

    public init(
        device: any DeviceDriver, decider: any Decider, udid: String,
        settleDelay: Duration = .milliseconds(500), logger: Logger = Logger(label: "simpilot")
    ) {
        self.device = device
        self.decider = decider
        self.udid = udid
        self.settleDelay = settleDelay
        self.logger = logger
    }

    public func run(
        _ plan: TestPlan,
        onStepFinished: @Sendable (Int, StepResult) -> Void = { _, _ in }
    ) async throws -> RunReport {
        let clock = ContinuousClock()
        let start = clock.now
        let pid = try await device.launch(bundleID: plan.app.bundleId, relaunch: plan.app.relaunch ?? true)
        try await Task.sleep(for: .seconds(1))

        let runner = StepRunner(
            device: device, decider: decider, app: plan.app.bundleId, expectedPID: pid,
            settleDelay: settleDelay, logger: logger
        )
        var results: [StepResult] = []
        for (index, step) in plan.steps.enumerated() {
            logger.info("step \(index + 1): \(step.goal)")
            let result = await runner.run(plan.resolved(step))
            results.append(result)
            onStepFinished(index, result)
            if result.status != .passed { break }
        }
        return RunReport(plan: plan.name, udid: udid, steps: results, durationMs: (clock.now - start).milliseconds)
    }
}
