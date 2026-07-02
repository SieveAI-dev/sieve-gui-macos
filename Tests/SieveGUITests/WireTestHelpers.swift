import Foundation
@testable import SieveGUICore

/// P2-1（决策响应 Codable 化）后测试用：把 Encodable wire 载荷转 [String: Any] 做字段断言。
/// 与生产编码管线（IPCOutbound.encodeParams → JSONSerialization）同构。
func wireJSONObject(_ value: some Encodable) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(value),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}
