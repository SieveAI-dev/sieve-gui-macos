import Testing
@testable import SieveGUICore

@Suite("SieveBinaryLocator — daemon 可执行路径解析")
struct SieveBinaryLocatorTests {
    @Test("候选路径优先于 PATH lookup")
    func candidate_path_wins_before_path_lookup() {
        let resolved = SieveBinaryLocator.resolve(
            isExecutable: { $0 == "/opt/homebrew/bin/sieve" },
            whichLookup: { "/tmp/sieve" }
        )

        #expect(resolved == "/opt/homebrew/bin/sieve")
    }

    @Test("候选路径缺失时回退 which sieve")
    func falls_back_to_which_lookup() {
        let resolved = SieveBinaryLocator.resolve(
            isExecutable: { _ in false },
            whichLookup: { "/Users/example/bin/sieve" }
        )

        #expect(resolved == "/Users/example/bin/sieve")
    }

    @Test("候选路径与 PATH 都缺失时返回 nil")
    func returns_nil_when_unavailable() {
        let resolved = SieveBinaryLocator.resolve(
            isExecutable: { _ in false },
            whichLookup: { nil }
        )

        #expect(resolved == nil)
    }
}
