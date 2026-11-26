import Foundation

/// Point coordinates may be negative on secondary displays. Invalid optional geometry
/// is discarded independently from healthy tab/pane state.
public struct WorkspaceWindowGeometry: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let sidebarWidth: Double
    public let informationWidth: Double

    public init?(x: Double, y: Double, width: Double, height: Double,
                 sidebarWidth: Double = 220, informationWidth: Double = 280) {
        guard [x, y, width, height].allSatisfy({ $0.isFinite && abs($0) <= 10_000_000 }),
              width > 0, height > 0 else { return nil }
        self.x = x; self.y = y; self.width = width; self.height = height
        self.sidebarWidth = sidebarWidth.isFinite ? min(320, max(180, sidebarWidth)) : 220
        self.informationWidth = informationWidth.isFinite ? min(420, max(240, informationWidth)) : 280
    }
    private enum CodingKeys: String, CodingKey { case x, y, width, height, sidebarWidth, informationWidth }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = Self(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y),
            width: try c.decode(Double.self, forKey: .width), height: try c.decode(Double.self, forKey: .height),
            sidebarWidth: (try? c.decode(Double.self, forKey: .sidebarWidth)) ?? 220,
            informationWidth: (try? c.decode(Double.self, forKey: .informationWidth)) ?? 280) else {
            throw DecodingError.dataCorruptedError(forKey: .width, in: c, debugDescription: "Invalid window coordinates or dimensions")
        }
        self = value
    }
}
