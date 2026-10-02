import Foundation
import Subprocess

/// Runs a command-line tool and returns its standard output.
enum Tool {
    struct Failure: Error, CustomStringConvertible {
        var command: String
        var status: String
        var stderr: String
        var description: String { "`\(command)` failed (\(status)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))" }
    }

    /// AXe (via idb) needs a full Xcode. When `xcode-select` points at the Command Line
    /// Tools, fall back to the first `/Applications/Xcode*.app` through `DEVELOPER_DIR`.
    static let environment: Environment = {
        let current = ProcessInfo.processInfo.environment
        if current["DEVELOPER_DIR"] != nil { return .inherit }
        // `xcode-select -s` stores its choice as this symlink.
        let selected = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? ""
        // A link to a deleted Xcode makes `xcode-select -p` fall back to the Command Line Tools too.
        let usable = !selected.contains("CommandLineTools") && FileManager.default.fileExists(atPath: selected)
        guard !usable else { return .inherit }
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        guard let xcode = apps.filter({ $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }).sorted().last else { return .inherit }
        return .inherit.updating(["DEVELOPER_DIR": "/Applications/\(xcode)/Contents/Developer"])
    }()

    @discardableResult
    static func run(_ name: String, _ arguments: [String]) async throws -> String {
        let result = try await Subprocess.run(
            .name(name),
            arguments: Arguments(arguments),
            environment: environment,
            output: .string(limit: 16 * 1024 * 1024),
            error: .string(limit: 64 * 1024)
        )
        guard result.terminationStatus.isSuccess else {
            throw Failure(
                command: ([name] + arguments).joined(separator: " "),
                status: "\(result.terminationStatus)",
                stderr: result.standardError
            )
        }
        return result.standardOutput
    }
}
