import SwiftUI

public struct SeverityChip: View {
    let severity: Severity
    public init(_ severity: Severity) { self.severity = severity }

    public var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
    }

    private var label: String {
        switch severity {
        case .critical: return "Critical"
        case .high: return "High"
        case .medium: return "Med"
        case .low: return "Low"
        }
    }

    private var background: Color {
        switch severity {
        case .critical: return .red.opacity(0.18)
        case .high: return .orange.opacity(0.18)
        case .medium: return .yellow.opacity(0.18)
        case .low: return .gray.opacity(0.18)
        }
    }

    private var foreground: Color {
        switch severity {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .secondary
        }
    }
}

public struct DirectionBadge: View {
    let direction: Direction
    public init(_ d: Direction) { self.direction = d }
    public var body: some View {
        Image(systemName: direction == .inbound ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
            .foregroundStyle(direction == .inbound ? .blue : .purple)
            .accessibilityLabel(direction == .inbound ? "入站" : "出站")
    }
}
