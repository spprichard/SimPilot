import CryptoKit
import Foundation

/// A visible, labelled element on screen, numbered for the model.
public struct Control: Sendable, Hashable, Codable {
    public var id: Int
    public var kind: String
    public var name: String
    public var value: String?
    public var uniqueID: String?
    public var frame: Rect
    public var enabled: Bool
    public var secure: Bool
    /// Hidden under a toolbar, tab bar or navigation bar the control does not belong to.
    public var occluded: Bool

    /// How the control is shown to Jev, e.g. `[3] Button · General`.
    public var candidateText: String {
        var text = "[\(id)] \(kind) · \(secure ? "(secure)" : name)"
        if let value, !value.isEmpty, value != name, !secure { text += " = \(value)" }
        return text
    }
}

/// The normalized state of one `describe-ui` observation.
public struct Snapshot: Sendable {
    public enum Purpose: Sendable { case tap, type }

    public var pid: Int32?
    public var screen: Rect
    public var controls: [Control]
    public var fingerprint: String

    static let tapKinds: Set<String> = ["Button", "Cell", "Link", "Switch", "TextField", "SearchField", "TextView", "SecureTextField"]
    static let typeKinds: Set<String> = ["TextField", "SearchField", "TextView"]
    static let barKinds: Set<String> = ["Toolbar", "TabBar", "NavigationBar"]
    static let barLabels: Set<String> = ["Toolbar", "Tab Bar"]
    static let secureWords = ["password", "passcode", "pin"]

    public init(elements: [AXElement]) {
        let root = elements.first
        pid = root?.pid
        screen = root?.frame ?? .zero

        var flat: [(element: AXElement, enabled: Bool, inBar: Bool)] = []
        var bars: [Rect] = []
        func walk(_ element: AXElement, parentEnabled: Bool, insideBar: Bool, ancestors: Set<String>) {
            let enabled = parentEnabled && (element.enabled ?? true)
            let isBar = Self.barKinds.contains(element.type ?? "")
                || Self.barLabels.contains(element.label ?? "")
                || Self.barLabels.contains(element.uniqueID ?? "")
            if isBar { bars.append(element.frame) }
            // Rows often nest a same-named button inside the row button; keep only the outer one.
            let identity = "\(element.type ?? "")|\(Self.name(of: element) ?? "")"
            if !ancestors.contains(identity) {
                flat.append((element, enabled, insideBar || isBar))
            }
            for child in element.children {
                walk(child, parentEnabled: enabled, insideBar: insideBar || isBar, ancestors: ancestors.union([identity]))
            }
        }
        for element in elements { walk(element, parentEnabled: true, insideBar: false, ancestors: []) }

        var seen = Set<String>()
        var controls: [Control] = []
        var inBar: [Bool] = []
        for (element, enabled, elementInBar) in flat {
            guard let kind = element.type, kind != "Application", kind != "Group" else { continue }
            guard let name = Self.name(of: element) else { continue }
            let frame = element.frame
            guard !frame.isEmpty, screen.isEmpty || screen.contains(x: frame.midX, y: frame.midY) else { continue }
            let key = "\(kind)|\(name)|\(Int(frame.x)),\(Int(frame.y)),\(Int(frame.width)),\(Int(frame.height))"
            guard seen.insert(key).inserted else { continue }
            controls.append(Control(
                id: controls.count + 1,
                kind: kind,
                name: name,
                value: element.value,
                uniqueID: element.uniqueID,
                frame: frame,
                enabled: enabled,
                secure: kind == "SecureTextField" || (Self.typeKinds.contains(kind) && Self.looksSecure(name)),
                occluded: false
            ))
            inBar.append(elementInBar)
        }

        // A control whose centre sits under a bar it is not part of would receive the bar's tap instead.
        for index in controls.indices where !inBar[index] {
            let frame = controls[index].frame
            controls[index].occluded = bars.contains { $0.contains(x: frame.midX, y: frame.midY) }
        }
        self.controls = controls

        var hasher = SHA256()
        hasher.update(data: Data("\(pid ?? 0)".utf8))
        for control in controls where control.kind != "Image" {
            hasher.update(data: Data("\(control.kind)|\(control.name)|\(Int(control.frame.x)),\(Int(control.frame.y))\n".utf8))
        }
        fingerprint = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Controls Jev may act on for a given purpose.
    public func targets(_ purpose: Purpose, allowLabels: [String]? = nil) -> [Control] {
        let kinds = purpose == .tap ? Self.tapKinds : Self.typeKinds
        return controls.filter { control in
            guard kinds.contains(control.kind), control.enabled, !control.occluded else { return false }
            if purpose == .type && control.secure { return false }
            if purpose == .tap, let allowLabels, !allowLabels.isEmpty {
                return allowLabels.contains { control.name.localizedCaseInsensitiveContains($0) }
            }
            return true
        }
    }

    /// Every visible label and value, used to verify expected text is on screen.
    public var labels: Set<String> {
        Set(controls.flatMap { [$0.name, $0.value].compactMap { $0 } })
    }

    public func contains(label: String) -> Bool {
        labels.contains(label)
    }

    public func control(id: Int) -> Control? {
        controls.first { $0.id == id }
    }

    static func looksSecure(_ name: String) -> Bool {
        let words = name.lowercased().split { !$0.isLetter }
        return words.contains { secureWords.contains(String($0)) }
    }

    static func name(of element: AXElement) -> String? {
        for candidate in [element.label, element.value, element.uniqueID] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
