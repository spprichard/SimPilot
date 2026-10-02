import Foundation
import Testing
@testable import SimPilotCore

@Suite struct RunnerTests {
    func device() throws -> FakeDevice {
        FakeDevice(
            start: "root",
            screens: ["root": try Fixture.elements("settings-root"), "general": try Fixture.elements("settings-general")],
            transitions: ["root": ["General": "general"], "general": ["Settings": "root"]],
            pid: 43353
        )
    }

    func step(_ goal: String, expect: [String], maxSteps: Int = 5, textValues: [String: String] = [:]) -> TestPlan.ResolvedStep {
        TestPlan.ResolvedStep(
            goal: goal, expectLabels: expect, allowLabels: nil, textValues: textValues,
            allowScroll: false, maxSteps: maxSteps, minProbability: 0.55
        )
    }

    func runner(_ device: FakeDevice, _ decider: ScriptedDecider, pid: Int32? = 43353) -> StepRunner {
        StepRunner(device: device, decider: decider, app: "com.apple.Preferences", expectedPID: pid, settleDelay: .zero)
    }

    @Test func passesWhenExpectedLabelsAppear() async throws {
        let device = try device()
        let decider = ScriptedDecider([(.tap, "General")])

        let result = await runner(device, decider).run(step("Open General", expect: ["About", "Keyboard"]))

        #expect(result.status == .passed)
        #expect(result.actions.count == 1)
        #expect(result.actions.first?.screenChanged == true)
        #expect(await device.taps == ["General"])
    }

    @Test func passesWithoutModelCallsWhenAlreadySatisfied() async throws {
        let decider = ScriptedDecider([])

        let result = await runner(try device(), decider).run(step("Be on Settings", expect: ["General"]))

        #expect(result.status == .passed)
        #expect(result.modelCalls == 0)
    }

    @Test func doneWithoutLabelsIsUnverified() async throws {
        let result = await runner(try device(), ScriptedDecider([(.done, nil)])).run(step("Open About", expect: ["iOS Version"]))

        #expect(result.status == .unverified)
    }

    @Test func tapsThatChangeNothingEndStuck() async throws {
        let decider = ScriptedDecider(Array(repeating: (.tap, "Search"), count: 5))

        let result = await runner(try device(), decider).run(step("Open About", expect: ["iOS Version"]))

        #expect(result.status == .stuck)
        #expect(result.actions.count == 3)
    }

    @Test func foreignProcessBlocks() async throws {
        let result = await runner(try device(), ScriptedDecider([]), pid: 1).run(step("Open General", expect: ["About"]))

        #expect(result.status == .blocked)
        #expect(result.reason?.contains("another process") == true)
    }

    @Test func typeTextTapsFieldThenTypesPlanValue() async throws {
        let device = try device()
        let decider = ScriptedDecider([(.typeText, "Search")])

        _ = await runner(device, decider).run(step("Search", expect: ["Nope"], maxSteps: 1, textValues: ["query": "Keyboard"]))

        #expect(await device.taps == ["Search"])
        #expect(await device.typed == ["Keyboard"])
    }

    @Test func planStopsAtFirstFailure() async throws {
        let plan = TestPlan(
            schema: TestPlan.schemaID, name: "t", app: .init(bundleId: "com.apple.Preferences", relaunch: true),
            defaults: .init(maxSteps: 3, minProbability: 0.5, allowScroll: false),
            steps: [
                .init(goal: "Open General", expectLabels: ["About"]),
                .init(goal: "Impossible", expectLabels: ["Does not exist"]),
                .init(goal: "Never runs", expectLabels: ["General"]),
            ]
        )
        let decider = ScriptedDecider([(.tap, "General"), (.done, nil)])
        let runner = PlanRunner(device: try device(), decider: decider, udid: "fake", settleDelay: .zero)

        let report = try await runner.run(plan)

        #expect(report.steps.map(\.status) == [.passed, .unverified])
        #expect(!report.passed)
    }
}

@Suite struct TestPlanTests {
    @Test func bundledSmokePlanIsValid() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plans/settings-smoke.json")
        let plan = try TestPlan.load(from: url)

        #expect(plan.steps.count == 3)
        #expect(plan.resolved(plan.steps[2]).textValues == ["query": "Keyboard"])
        #expect(plan.resolved(plan.steps[0]).maxSteps == 8)
    }

    @Test func rejectsMissingExpectLabels() {
        let plan = TestPlan(
            schema: TestPlan.schemaID, name: "t", app: .init(bundleId: "x", relaunch: nil), defaults: nil,
            steps: [.init(goal: "g", expectLabels: [])]
        )

        #expect(throws: SimPilotError.self) { try plan.validate() }
    }
}
