import ArgumentParser
import Foundation
import Logging
import SimPilotCore
import TypeSafe

@main
struct SimPilot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simpilot",
        abstract: "Drive the iOS Simulator with TypeSafe's Jev and AXe to execute JSON test plans.",
        subcommands: [Run.self, Inspect.self, Doctor.self],
        defaultSubcommand: Run.self
    )
}

struct DeviceOptions: ParsableArguments {
    @Option(help: "Simulator UDID, or `booted` for the single booted simulator.")
    var udid = "booted"
}

extension SimPilot {
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a test plan against a simulator.")

        @Argument(help: "Path to a simpilot/plan/v1 JSON file.")
        var plan: String

        @OptionGroup var device: DeviceOptions

        @Option(help: "Write the full JSON report to this path.")
        var report: String?

        @Option(help: "Jev model to use (defaults to the SDK default, jev-latest).")
        var model: String?

        @Option(help: "Milliseconds to wait after each action for the UI to settle.")
        var settleMs = 500

        @Flag(name: .shortAndLong, help: "Log every decision.")
        var verbose = false

        func run() async throws {
            let logger = makeLogger(verbose: verbose)
            let plan = try TestPlan.load(from: URL(fileURLWithPath: plan))
            let driver = try await AXeDevice.resolve(device.udid)
            let decider = JevDecider(client: try TypeSafeClient(), model: model)
            let runner = PlanRunner(
                device: driver, decider: decider, udid: driver.udid,
                settleDelay: .milliseconds(settleMs), logger: logger
            )

            print("▶ \(plan.name) on \(driver.udid)")
            let result = try await runner.run(plan) { index, step in
                let symbol = step.status == .passed ? "✓" : "✗"
                var line = "\(symbol) \(index + 1). \(step.goal) — \(step.status.rawValue)"
                line += " (\(step.actions.count) actions, \(step.modelCalls) Jev calls, \(Int(step.durationMs)) ms)"
                print(line)
                if let reason = step.reason { print("    \(reason)") }
            }

            let median = result.medianLatencyMs.map { "\(Int($0)) ms" } ?? "n/a"
            print("")
            print("\(result.passed ? "PASSED" : "FAILED") — \(result.steps.count)/\(plan.steps.count) steps run, \(result.modelCalls) Jev calls, median Jev latency \(median), tokens \(result.inputTokens) in / \(result.outputTokens) out, \(String(format: "%.1f", result.durationMs / 1000)) s total")

            if let report {
                try result.json().write(to: URL(fileURLWithPath: report))
                print("Report: \(report)")
            }
            if !result.passed { throw ExitCode.failure }
        }
    }

    struct Inspect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the numbered controls Jev would see on the current screen.")

        @OptionGroup var device: DeviceOptions

        @Flag(help: "Show every labelled element, not just tap/type targets.")
        var all = false

        func run() async throws {
            let driver = try await AXeDevice.resolve(device.udid)
            let snapshot = Snapshot(elements: try await driver.describeUI())
            let tap = Set(snapshot.targets(.tap).map(\.id))
            let type = Set(snapshot.targets(.type).map(\.id))
            print("pid \(snapshot.pid.map(String.init) ?? "?") · fingerprint \(snapshot.fingerprint) · \(snapshot.controls.count) elements")
            for control in snapshot.controls where all || tap.contains(control.id) || type.contains(control.id) {
                var tags: [String] = []
                if tap.contains(control.id) { tags.append("tap") }
                if type.contains(control.id) { tags.append("type") }
                if control.occluded { tags.append("occluded") }
                if !control.enabled { tags.append("disabled") }
                print("\(control.candidateText)\(tags.isEmpty ? "" : "  [\(tags.joined(separator: ","))]")")
            }
        }
    }

    struct Doctor: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check AXe, the simulator, and the TypeSafe API key.")

        @OptionGroup var device: DeviceOptions

        func run() async throws {
            var ok = true
            func check(_ name: String, _ body: () async throws -> String) async {
                do {
                    print("✓ \(name): \(try await body())")
                } catch {
                    ok = false
                    print("✗ \(name): \(error)")
                }
            }

            var driver: AXeDevice?
            await check("simulator") {
                driver = try await AXeDevice.resolve(device.udid)
                return driver!.udid
            }
            await check("axe describe-ui") {
                guard let driver else { throw ValidationError("no simulator") }
                let snapshot = Snapshot(elements: try await driver.describeUI())
                return "\(snapshot.controls.count) elements on screen"
            }
            await check("TYPESAFE_API_KEY") {
                guard ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] != nil else {
                    throw ValidationError("not set (add it to .envrc)")
                }
                return "set"
            }
            await check("TypeSafe API") {
                let models = try await TypeSafeClient().listModels()
                return models.map(\.name).joined(separator: ", ")
            }
            if !ok { throw ExitCode.failure }
        }
    }
}

func makeLogger(verbose: Bool) -> Logger {
    LoggingSystem.bootstrap { StreamLogHandler.standardError(label: $0) }
    var logger = Logger(label: "simpilot")
    logger.logLevel = verbose ? .debug : .warning
    return logger
}
