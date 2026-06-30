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
            HStack {
                Text("链路").font(.caption).foregroundStyle(.secondary)
                Text(value.chain).font(.callout)
                if let cid = value.chainId { Text("(\(cid))").font(.caption2).foregroundStyle(.tertiary) }
            }
            if let flags = value.flags {
                HStack(spacing: 6) {
                    if flags.infiniteAmount { Tag("Infinite Amount", color: .red) }
                    if flags.deadlineZero { Tag("Deadline=0", color: .red) }
                    if flags.approveAll { Tag("Approve All", color: .red) }
                }
            }
            // EIP-712 typed_data 解析渲染
            if let typedData = value.typedData {
                EIP712View(rawData: typedData.rawData, isUnlocked: isUnlocked)
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

// MARK: - EIP-712 渲染

/// EIP-712 typed_data 解析与渲染。
/// 结构：{domain: {name, version, chainId, verifyingContract}, types: {...}, primaryType: String, message: {...}}
public struct EIP712View: View {
    let rawData: Data
    let isUnlocked: Bool

    private var parsed: EIP712Parsed? { EIP712Parser.parse(rawData) }

    public var body: some View {
        if let p = parsed {
            VStack(alignment: .leading, spacing: 8) {
                // 域名信息（安全关键）
                domainSection(p.domain)
                // primaryType + message 字段表
                if let primaryType = p.primaryType, !primaryType.isEmpty {
                    messageSection(primaryType: primaryType, message: p.message)
                }
            }
        } else {
            // 解析失败降级
            Text("typed_data（格式不识别）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func domainSection(_ domain: EIP712Parsed.Domain) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EIP-712 Domain").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let name = domain.name {
                row("协议名", name)
            }
            if let chainId = domain.chainId {
                row("Chain ID", "\(chainId)")
            }
            if let contract = domain.verifyingContract {
                // 合约地址是敏感字段，走 MaskedField
                HStack(alignment: .top, spacing: 4) {
                    Text("合约").font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                    MaskedField(contract, style: .prefix4Suffix4, isUnlocked: isUnlocked)
                }
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func messageSection(primaryType: String, message: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Message (\(primaryType))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(message.sorted(by: { $0.key < $1.key }), id: \.key) { key, val in
                if isEthAddress(val) || isHexSecret(val) {
                    HStack(alignment: .top, spacing: 4) {
                        Text(key).font(.caption).foregroundStyle(.secondary).frame(minWidth: 60, alignment: .leading)
                        MaskedField(val, style: .prefix4Suffix4, isUnlocked: isUnlocked)
                    }
                } else {
                    row(key, val)
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(minWidth: 60, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).foregroundStyle(.primary).textSelection(.enabled)
        }
    }

    /// 判断是否是以太坊地址（0x + 40 hex）
    private func isEthAddress(_ s: String) -> Bool {
        guard s.hasPrefix("0x") || s.hasPrefix("0X") else { return false }
        let hex = s.dropFirst(2)
        return hex.count == 40 && hex.allSatisfy { $0.isHexDigit }
    }

    /// 判断是否是长 hex 串（私钥、签名等）
    private func isHexSecret(_ s: String) -> Bool {
        let stripped = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
        return stripped.count >= 64 && stripped.allSatisfy { $0.isHexDigit }
    }
}

// MARK: - EIP-712 解析器

struct EIP712Parsed {
    struct Domain {
        let name: String?
        let version: String?
        let chainId: Int?
        let verifyingContract: String?
    }
    let domain: Domain
    let primaryType: String?
    let message: [String: String]  // 展平为 key: value 字符串（含嵌套）
}

enum EIP712Parser {
    static func parse(_ data: Data) -> EIP712Parsed? {
        guard case .object(let root) = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }

        // domain
        let domainObj: [String: JSONValue]
        if case .object(let d) = root["domain"] { domainObj = d } else { domainObj = [:] }
        let domain = EIP712Parsed.Domain(
            name: domainObj["name"]?.asString,
            version: domainObj["version"]?.asString,
            chainId: extractChainId(domainObj["chainId"] ?? domainObj["chain_id"]),
            verifyingContract: domainObj["verifyingContract"]?.asString ?? domainObj["verifying_contract"]?.asString
        )

        let primaryType = root["primaryType"]?.asString
        // message 展平为字符串映射
        let messageDict: [String: String]
        if case .object(let m) = root["message"] {
            messageDict = flattenJSONObject(m)
        } else {
            messageDict = [:]
        }

        return EIP712Parsed(domain: domain, primaryType: primaryType, message: messageDict)
    }

    private static func extractChainId(_ v: JSONValue?) -> Int? {
        guard let v = v else { return nil }
        switch v {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s) ?? (s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : nil)
        default: return nil
        }
    }

    /// 展平 JSON object 为 [key: stringValue]，嵌套 object 用 "key.subkey" 格式
    private static func flattenJSONObject(_ obj: [String: JSONValue], prefix: String = "") -> [String: String] {
        var result: [String: String] = [:]
        for (key, val) in obj {
            let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
            switch val {
            case .object(let nested):
                result.merge(flattenJSONObject(nested, prefix: fullKey)) { _, new in new }
            case .null:
                result[fullKey] = "null"
            default:
                result[fullKey] = jsonValueToString(val)
            }
        }
        return result
    }

    private static func jsonValueToString(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return "\(i)"
        case .double(let d): return "\(d)"
        case .string(let s): return s
        case .array(let arr): return "[\(arr.map { jsonValueToString($0) }.joined(separator: ", "))]"
        case .object(let o):
            let pairs = o.sorted { $0.key < $1.key }.map { "\($0.key): \(jsonValueToString($0.value))" }
            return "{\(pairs.joined(separator: ", "))}"
        }
    }
}

public struct MarkdownExfilCard: View {
    let value: HipsContext.MarkdownExfil
    private var presentation: MarkdownExfilPresentation {
        MarkdownExfilPresentation(value: value)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("模型回复片段").font(.caption).foregroundStyle(.secondary)
            Text(presentation.maskedSnippet)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.gray.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("外链 URL").font(.caption).foregroundStyle(.secondary)
            ForEach(presentation.urlRows) { row in
                HStack {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    Text(row.maskedURL).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(row.reachabilityLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(row.reachable == true ? Color.orange.opacity(0.15) : Color.gray.opacity(0.15))
                        .foregroundStyle(row.reachable == true ? Color.orange : Color.secondary)
                        .clipShape(Capsule())
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
