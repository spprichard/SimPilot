import Foundation

public enum ScrollDirection: String, Sendable, Codable {
    case up, down
}

/// Observes and drives one simulator. `AXeDevice` is the real implementation; tests use a fake.
public protocol DeviceDriver: Sendable {
    func describeUI() async throws -> [AXElement]
    func tap(x: Double, y: Double) async throws
    func type(_ text: String) async throws
    func scroll(_ direction: ScrollDirection) async throws
    /// Launches (optionally relaunching) the app and returns its pid.
    func launch(bundleID: String, relaunch: Bool) async throws -> Int32
}

/// Drives a booted iOS Simulator through the AXe CLI and `xcrun simctl`.
public struct AXeDevice: DeviceDriver {
    public let udid: String

    public init(udid: String) {
        self.udid = udid
    }

    /// Resolves `booted` (or nil) to the UDID of the single booted simulator.
    public static func resolve(_ udid: String?) async throws -> AXeDevice {
        if let udid, udid != "booted" { return AXeDevice(udid: udid) }
        let output = try await Tool.run("xcrun", ["simctl", "list", "devices", "booted", "--json"])
        struct List: Decodable { var devices: [String: [Device]] }
        struct Device: Decodable { var udid: String; var name: String }
        let booted = try JSONDecoder().decode(List.self, from: Data(output.utf8)).devices.values.flatMap { $0 }
        guard let device = booted.first else { throw SimPilotError.noBootedSimulator }
        guard booted.count == 1 else { throw SimPilotError.multipleBootedSimulators(booted.map(\.name)) }
        return AXeDevice(udid: device.udid)
    }

    public func describeUI() async throws -> [AXElement] {
        let output = try await Tool.run("axe", ["describe-ui", "--udid", udid])
        return try JSONDecoder().decode([AXElement].self, from: Data(output.utf8))
    }

    public func tap(x: Double, y: Double) async throws {
        // The default simulator tap style reports success without navigating in iOS 26 Settings.
        try await Tool.run("axe", ["tap", "-x", Self.format(x), "-y", Self.format(y), "--tap-style", "physical", "--udid", udid])
    }

    public func type(_ text: String) async throws {
        try await Tool.run("axe", ["type", text, "--udid", udid])
    }

    public func scroll(_ direction: ScrollDirection) async throws {
        // AXe's scroll-down gesture moves content down (reveals what is above), so map from reading direction.
        let gesture = direction == .down ? "scroll-up" : "scroll-down"
        try await Tool.run("axe", ["gesture", gesture, "--udid", udid])
    }

    public func launch(bundleID: String, relaunch: Bool) async throws -> Int32 {
        var arguments = ["simctl", "launch"]
        if relaunch { arguments.append("--terminate-running-process") }
        arguments += [udid, bundleID]
        let output = try await Tool.run("xcrun", arguments)
        // Output looks like "com.apple.Preferences: 43353".
        guard let pid = output.split(separator: ":").last.flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else {
            throw SimPilotError.unexpectedOutput(command: "simctl launch", output: output)
        }
        return pid
    }

    static func format(_ value: Double) -> String {
        String(Int(value.rounded()))
    }
}

public enum SimPilotError: Error, CustomStringConvertible {
    case noBootedSimulator
    case multipleBootedSimulators([String])
    case unexpectedOutput(command: String, output: String)
    case invalidPlan(String)

    public var description: String {
        switch self {
        case .noBootedSimulator: "No booted simulator. Boot one with `xcrun simctl boot <udid>` or pass --udid."
        case .multipleBootedSimulators(let names): "Several simulators are booted (\(names.joined(separator: ", "))); pass --udid."
        case .unexpectedOutput(let command, let output): "Unexpected output from \(command): \(output)"
        case .invalidPlan(let reason): "Invalid plan: \(reason)"
        }
    }
}
