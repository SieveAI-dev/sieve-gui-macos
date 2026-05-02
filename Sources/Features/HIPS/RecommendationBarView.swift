import SwiftUI

public struct RecommendationBarView: View {
    let recommendation: Recommendation

    public init(recommendation: Recommendation) {
        self.recommendation = recommendation
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(label).font(.subheadline.weight(.semibold))
                    Text("置信度：\(confidenceLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let r = recommendation.reason {
                    Text(r)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch recommendation.decision {
        case .deny: return "shield.lefthalf.filled.badge.checkmark"
        case .allow: return "checkmark.shield"
        }
    }

    private var color: Color {
        switch recommendation.decision {
        case .deny: return .red
        case .allow: return .green
        }
    }

    private var label: String {
        switch recommendation.decision {
        case .deny: return "建议拒绝"
        case .allow: return "建议允许"
        }
    }

    private var confidenceLabel: String {
        switch recommendation.confidence {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }
}
