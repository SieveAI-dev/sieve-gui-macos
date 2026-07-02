import SwiftUI

public struct SeverityChip: View {
    let severity: Severity
    public init(_ severity: Severity) {
        self.severity = severity
    }

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
        case .critical: "Critical"
        case .high: "High"
        case .medium: "Med"
        case .low: "Low"
        }
    }

    private var background: Color {
        switch severity {
        case .critical: .red.opacity(0.18)
        case .high: .orange.opacity(0.18)
        case .medium: .yellow.opacity(0.18)
        case .low: .gray.opacity(0.18)
        }
    }

    private var foreground: Color {
        switch severity {
        case .critical: .red
        case .high: .orange
        case .medium: .yellow
        case .low: .secondary
        }
    }
}

public struct DirectionBadge: View {
    let direction: Direction
    public init(_ d: Direction) {
        direction = d
    }

    public var body: some View {
        Image(systemName: direction == .inbound ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
            .foregroundStyle(direction == .inbound ? .blue : .purple)
            .accessibilityLabel(direction == .inbound ? "入站" : "出站")
    }
}
