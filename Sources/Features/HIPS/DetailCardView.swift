import SwiftUI

/// 五种 template 的细节卡片入口。
public struct DetailCardView: View {
    let ruleId: String
    let context: HipsContext
    let recommendation: Recommendation?
    let isUnlocked: Bool

    public init(ruleId: String, context: HipsContext, recommendation: Recommendation?, isUnlocked: Bool) {
        self.ruleId = ruleId
        self.context = context
        self.recommendation = recommendation
        self.isUnlocked = isUnlocked
    }

    public var body: some View {
        switch context {
        case .addressCompare(let v):
            AddressCompareCard(value: v, isUnlocked: isUnlocked)
        case .signingToolUse(let v):
            SigningToolUseCard(value: v, isUnlocked: isUnlocked)
        case .markdownExfil(let v):
            MarkdownExfilCard(value: v)
        case .secretOutbound(let v):
            SecretOutboundCard(value: v)
        case .generic(let v):
            GenericPayloadCard(value: v, isUnlocked: isUnlocked)
        }
    }
}

// MARK: - 单 issue 合并视图

public struct IssueCardView: View {
    let issue: HipsIssue
    let isUnlocked: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SeverityChip(issue.severity)
                Text(issue.ruleId).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !issue.allowRemember {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(issue.title).font(.subheadline.weight(.semibold))
            DetailCardView(ruleId: issue.ruleId, context: issue.context, recommendation: issue.recommendation, isUnlocked: isUnlocked)
            if let rec = issue.recommendation {
                RecommendationBarView(recommendation: rec)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Templates

public struct AddressCompareCard: View {
    let value: HipsContext.AddressCompare
    let isUnlocked: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("链路", value.chain)
            label("Levenshtein", "\(value.levenshtein)")
            VStack(alignment: .leading, spacing: 4) {
                Text("原始地址").font(.caption).foregroundStyle(.secondary)
                MaskedField(value.originalAddress, style: .prefix4Suffix4, isUnlocked: isUnlocked)
                Text("替换为").font(.caption).foregroundStyle(.secondary)
                MaskedField(value.substitutedAddress, style: .prefix4Suffix4, isUnlocked: isUnlocked)
            }
        }
    }

    private func label(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.caption).foregroundStyle(.secondary); Text(v).font(.callout) }
    }
}

public struct SigningToolUseCard: View {
    let value: HipsContext.SigningToolUse
    let isUnlocked: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("工具").font(.caption).foregroundStyle(.secondary); Text(value.toolName).font(.callout.weight(.medium)) }
            HStack { Text("链路").font(.caption).foregroundStyle(.secondary); Text(value.chain).font(.callout); if let cid = value.chainId { Text("(\(cid))").font(.caption2).foregroundStyle(.tertiary) } }
            if let flags = value.flags {
                HStack(spacing: 6) {
                    if flags.infiniteAmount { Tag("Infinite Amount", color: .red) }
                    if flags.deadlineZero { Tag("Deadline=0", color: .red) }
                    if flags.approveAll { Tag("Approve All", color: .red) }
                }
            }
            if value.typedData != nil {
                Text("typed_data 详情仅在解锁后展示").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private struct Tag: View {
        let title: String
        let color: Color
        init(_ t: String, color: Color) { self.title = t; self.color = color }
        var body: some View {
            Text(title)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color.opacity(0.15)).foregroundStyle(color)
                .clipShape(Capsule())
        }
    }
}

public struct MarkdownExfilCard: View {
    let value: HipsContext.MarkdownExfil
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("外链 URL").font(.caption).foregroundStyle(.secondary)
            ForEach(value.urls, id: \.self) { url in
                HStack {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    Text(url).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

public struct SecretOutboundCard: View {
    let value: HipsContext.SecretOutbound
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("种类").font(.caption).foregroundStyle(.secondary); Text(value.secretKind).font(.callout) }
            HStack { Text("长度").font(.caption).foregroundStyle(.secondary); Text("\(value.length)").font(.callout) }
            HStack(spacing: 6) {
                Text(value.prefix4).font(.system(.callout, design: .monospaced))
                Text("…").foregroundStyle(.secondary)
                Text(value.suffix4).font(.system(.callout, design: .monospaced))
            }
            HStack {
                Text("hash").font(.caption).foregroundStyle(.secondary)
                Text(value.hashShort).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
    }
}

public struct GenericPayloadCard: View {
    let value: HipsContext.GenericPayload
    let isUnlocked: Bool
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Payload (JSON)").font(.caption).foregroundStyle(.secondary)
            if isUnlocked, let s = String(data: value.payload.rawData, encoding: .utf8) {
                ScrollView {
                    Text(s)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            } else {
                MaskedField(String(data: value.payload.rawData, encoding: .utf8) ?? "", style: .clearWhenUnlocked, isUnlocked: false)
            }
        }
    }
}
