/// One node of `axe describe-ui` output. Only the fields SimPilot reads are decoded.
public struct AXElement: Decodable, Sendable, Hashable {
    public var type: String?
    public var label: String?
    public var value: String?
    public var uniqueID: String?
    public var frame: Rect
    public var enabled: Bool?
    public var pid: Int32?
    public var children: [AXElement]

    enum CodingKeys: String, CodingKey {
        case type, frame, enabled, pid, children
        case label = "AXLabel"
        case value = "AXValue"
        case uniqueID = "AXUniqueId"
    }

    public init(
        type: String?, label: String? = nil, value: String? = nil, uniqueID: String? = nil,
        frame: Rect, enabled: Bool? = true, pid: Int32? = nil, children: [AXElement] = []
    ) {
        self.type = type
        self.label = label
        self.value = value
        self.uniqueID = uniqueID
        self.frame = frame
        self.enabled = enabled
        self.pid = pid
        self.children = children
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        uniqueID = try container.decodeIfPresent(String.self, forKey: .uniqueID)
        frame = try container.decodeIfPresent(Rect.self, forKey: .frame) ?? .zero
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
        children = try container.decodeIfPresent([AXElement].self, forKey: .children) ?? []
    }
}

/// A screen rectangle in points, as AXe reports it.
public struct Rect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= x + width && py >= y && py <= y + height
    }
}
