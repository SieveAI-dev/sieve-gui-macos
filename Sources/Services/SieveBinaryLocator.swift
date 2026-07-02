import Foundation

/// 解析 sieve daemon 可执行文件的绝对路径。
///
/// Apple Silicon 上 Homebrew 默认装在 `/opt/homebrew/bin`，Intel 装在 `/usr/local/bin`，
/// 也可能落在 PATH 的其他位置——硬编码单一 `/usr/local/bin/sieve` 会在多数 ARM Mac 上
/// 静默失败（按钮点了没反应）。统一走本类解析，调用方据 nil 给出反馈而非默默无效。
public enum SieveBinaryLocator {
    /// 已知候选安装路径（按优先级：ARM Homebrew → Intel Homebrew）。
    public static let candidatePaths = ["/opt/homebrew/bin/sieve", "/usr/local/bin/sieve"]

    /// 解析 sieve 可执行文件路径：先查已知路径，再回退 `which sieve`。找不到返回 nil。
    public static func resolve() -> String? {
        resolve(isExecutable: FileManager.default.isExecutableFile(atPath:), whichLookup: whichSieve)
    }

    static func resolve(
        isExecutable: (String) -> Bool,
        whichLookup: () -> String?
    ) -> String? {
        for path in candidatePaths where isExecutable(path) {
            return path
        }
        return whichLookup()
    }

    private static func whichSieve() -> String? {
        let p = Process()
        p.launchPath = "/usr/bin/which"
        p.arguments = ["sieve"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }
}
