import Testing
@testable import RiptideCore

struct RichContentTests {
    @Test func keepsIncompleteStreamingLineOutsideStableMarkdown() {
        let before = MarkdownStreamSource("Heading\r\n~~~mermaid\nflowchart LR\n~~", streaming: true)
        let stillPending = MarkdownStreamSource("Heading\r\n~~~mermaid\nflowchart LR\n~~~", streaming: true)
        let finishedFence = MarkdownStreamSource("Heading\r\n~~~mermaid\nflowchart LR\n~~~\nNext", streaming: true)
        #expect(before.committed == stillPending.committed)
        #expect(before.pending == "~~")
        #expect(stillPending.pending == "~~~")
        #expect(finishedFence.committed.hasSuffix("~~~\n"))
        #expect(finishedFence.pending == "Next")
        #expect(MarkdownStreamSource("Final line", streaming: false).committed == "Final line")
    }

    @Test func recognizesOnlyCompatibleClosingFences() {
        #expect(MarkdownStreamSource.closesFence(opening: "~~~~mermaid", closing: ">  ~~~~~  "))
        #expect(!MarkdownStreamSource.closesFence(opening: "~~~~mermaid", closing: "~~~"))
        #expect(!MarkdownStreamSource.closesFence(opening: "~~~mermaid", closing: "```"))
        #expect(!MarkdownStreamSource.closesFence(opening: "~~~mermaid", closing: "~~~ still content"))
        #expect(!MarkdownStreamSource.closesFence(opening: "~~mermaid", closing: "~~~"))
    }

    @Test func diffSeparatesFileHeadersFromHunkContentAndTracksBothSides() {
        let text = """
        diff --git a/first b/first
        --- a/first
        +++ b/first
        @@ -7,2 +12,2 @@
         context
        ---- removed content starts with dashes
        ++++ added content starts with pluses
        diff --git a/new b/new
        --- /dev/null
        +++ b/new
        @@ -0,0 +1 @@
        +next
        """
        let diff = UnifiedDiff(text)
        #expect(diff.additions == 2)
        #expect(diff.deletions == 1)
        #expect(diff.lines[2].kind == .file)
        #expect(diff.lines[4].oldNumber == 7)
        #expect(diff.lines[4].newNumber == 12)
        #expect(diff.lines[5].kind == .deletion)
        #expect(diff.lines[5].oldNumber == 8)
        #expect(diff.lines[5].newNumber == nil)
        #expect(diff.lines[6].newNumber == 13)
        #expect(diff.lines.last?.newNumber == 1)
        #expect(!diff.truncated)
        #expect(UnifiedDiff(text, limit: 4).truncated)
    }
}
