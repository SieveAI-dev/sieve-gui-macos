import Foundation
import os.log

/// 导出诊断包。强制脱敏（[ADR-011](docs/design/adr/ADR-011-redact-on-export.md)）。
/// 不提供"明文导出"选项。
public actor DiagnosticPackager {
    public static let shared = DiagnosticPackager()
    private let logger = Logger(subsystem: "com.sieve.gui", category: "diagnostic")

    /// 排除字段：prefix_hash / suffix_hash / session_id / caller_pid / caller_exe完整路径 / evidence_meta 原文
    public static let redactedFields: Set<String> = [
        "prefix_hash", "suffix_hash", "session_id",
        "caller_pid", "caller_exe", "evidence_meta",
        "fingerprint"
    ]

    public func exportRedacted() async -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        let outURL = downloads.appendingPathComponent("sieve-diagnostic-\(stamp).zip")

        // 1. 收集源文件
        let sources: [URL] = [
            URL(fileURLWithPath: NSHomeDirectory() + "/.sieve/gui.log"),
            URL(fileURLWithPath: NSHomeDirectory() + "/.sieve/gui.log.1")
        ].filter { fm.fileExists(atPath: $0.path) }

        // 2. 创建临时目录，复制脱敏后的文件
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("sieve-diag-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        for src in sources {
            let dst = tmpDir.appendingPathComponent(src.lastPathComponent)
            if let data = try? Data(contentsOf: src) {
                let red = redactLogData(data)
                try? red.write(to: dst)
            }
        }

        // 3. 写一个 README 说明
        let readme = """
        Sieve GUI Diagnostic Bundle
        ----------------------------
        Exported: \(Date())
        GUI version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")
        本包已自动脱敏：移除 fingerprint / session_id / caller_pid / evidence_meta 原文。
        """
        try? readme.data(using: .utf8)?.write(to: tmpDir.appendingPathComponent("README.txt"))

        // 4. 调用 ditto 打成 zip
        let proc = Process()
        proc.launchPath = "/usr/bin/ditto"
        proc.arguments = ["-c", "-k", "--keepParent", tmpDir.path, outURL.path]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0 ? outURL : nil
        } catch {
            logger.error("diagnostic zip failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 简单的字段名级别脱敏：把含敏感字段名的整行替换为 ••••。
    private func redactLogData(_ data: Data) -> Data {
        guard let s = String(data: data, encoding: .utf8) else { return data }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        let redacted = lines.map { line -> String in
            for f in DiagnosticPackager.redactedFields {
                if line.contains(f) {
                    return "[REDACTED LINE — contained \(f)]"
                }
            }
            return String(line)
        }
        return redacted.joined(separator: "\n").data(using: .utf8) ?? data
    }
}
