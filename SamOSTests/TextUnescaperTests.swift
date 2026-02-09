import XCTest
@testable import SamOS

final class TextUnescaperTests: XCTestCase {

    private final class PassThroughMarkdownRuntime: ToolsRuntimeProtocol {
        func execute(_ toolAction: ToolAction) -> OutputItem? {
            OutputItem(kind: .markdown, payload: toolAction.args["markdown"] ?? "")
        }
    }

    private final class StructuredMarkdownRuntime: ToolsRuntimeProtocol {
        func execute(_ toolAction: ToolAction) -> OutputItem? {
            let formatted = toolAction.args["markdown"] ?? ""
            let payload: [String: Any] = [
                "spoken": "Here you go.",
                "formatted": formatted
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            return OutputItem(kind: .markdown, payload: json)
        }
    }

    // MARK: - Escaped newlines

    func testLiteralBackslashN_BecomesNewline() {
        let input = "Step 1: Do this\\nStep 2: Do that"
        let result = TextUnescaper.normalizeLLMText(input)
        XCTAssertTrue(result.contains("\n"), "Literal \\n should become real newline")
        XCTAssertEqual(result, "Step 1: Do this\nStep 2: Do that")
    }

    func testLiteralBackslashRN_BecomesNewline() {
        let input = "Line one\\r\\nLine two"
        let result = TextUnescaper.normalizeLLMText(input)
        XCTAssertEqual(result, "Line one\nLine two")
    }

    // MARK: - Escaped tabs

    func testLiteralBackslashT_BecomesFourSpaces() {
        let input = "Item:\\tvalue"
        let result = TextUnescaper.normalizeLLMText(input)
        XCTAssertEqual(result, "Item:    value")
    }

    // MARK: - Unicode sequences

    func testUnicodeEscape_DecodesCorrectly() {
        let input = "caf\\u00e9"
        let result = TextUnescaper.normalizeLLMText(input)
        XCTAssertEqual(result, "café")
    }

    // MARK: - Markdown preservation

    func testMarkdownSymbolsPreserved() {
        let input = "# Title\\n\\n- Item 1\\n- Item 2\\n\\n1. First\\n2. Second"
        let result = TextUnescaper.normalizeLLMText(input)
        XCTAssertTrue(result.hasPrefix("# Title"))
        XCTAssertTrue(result.contains("- Item 1"))
        XCTAssertTrue(result.contains("1. First"))
    }

    // MARK: - CRLF normalization

    func testRealCRLF_NormalizedToLF() {
        let input = "Line one\r\nLine two\rLine three"
        let result = TextUnescaper.normalizeLLMText(input)
        XCTAssertFalse(result.contains("\r"))
        XCTAssertEqual(result, "Line one\nLine two\nLine three")
    }

    // MARK: - Already-clean text

    func testCleanText_Unchanged() {
        let input = "Hello, how are you?"
        let result = TextUnescaper.normalizeLLMText(input)
        XCTAssertEqual(result, input)
    }

    // MARK: - Paragraph break preprocessing

    func testEnsureParagraphBreaks_SingleNewlinesDoubled() {
        let input = "# Title\n\nLine1\nLine2"
        let result = TextUnescaper.ensureParagraphBreaks(input)
        // Single newlines become double; existing double newlines stay unchanged
        XCTAssertEqual(result, "# Title\n\nLine1\n\nLine2")
    }

    // MARK: - Show_text markdown rendering

    func testShowTextMarkdown_RendersWithRealNewlines() {
        // Simulates what OpenAI returns in show_text markdown field
        let input = "# Butter Chicken\\n\\n## Ingredients\\n- 500g chicken\\n- 2 tbsp butter\\n\\n## Steps\\n1. Marinate chicken\\n2. Cook in sauce"
        let result = TextUnescaper.normalizeLLMText(input)
        let lines = result.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "# Butter Chicken")
        XCTAssertEqual(lines[1], "")
        XCTAssertEqual(lines[2], "## Ingredients")
        XCTAssertTrue(lines[3].hasPrefix("- "))
    }

    // MARK: - Tool markdown passthrough

    @MainActor
    func testToolMarkdownPayloadPreservedForOutputCanvas() async {
        let markdown = "# Title\n\n## Ingredients:\n- a\n- b\n\nLine1\nLine2"
        let executor = PlanExecutor(toolsRuntime: PassThroughMarkdownRuntime())
        let plan = Plan(steps: [
            .tool(name: "show_text", args: ["markdown": .string(markdown)], say: nil)
        ])

        let result = await executor.execute(plan, originalInput: "show me text")

        XCTAssertEqual(result.outputItems.count, 1)
        XCTAssertEqual(result.outputItems.first?.kind, .markdown)
        XCTAssertEqual(result.outputItems.first?.payload, markdown)
        XCTAssertTrue(result.outputItems.first?.payload.contains("\n- a\n- b\n") == true)
    }

    @MainActor
    func testStructuredFormattedMarkdownPreservedForOutputCanvas() async {
        let markdown = "# Title\n\n## Ingredients:\n- a\n- b\n\nLine1\nLine2"
        let executor = PlanExecutor(toolsRuntime: StructuredMarkdownRuntime())
        let plan = Plan(steps: [
            .tool(name: "show_text", args: ["markdown": .string(markdown)], say: nil)
        ])

        let result = await executor.execute(plan, originalInput: "show me text")

        XCTAssertEqual(result.outputItems.count, 1)
        XCTAssertEqual(result.outputItems.first?.kind, .markdown)
        XCTAssertEqual(result.outputItems.first?.payload, markdown)
        XCTAssertTrue(result.outputItems.first?.payload.contains("\n- a\n- b\n") == true)
    }

    // MARK: - Output canvas fenced code blocks

    func testOutputCanvasMarkdownParsesFencedCodeBlock() {
        let markdown = """
        # Log

        ```text
        {
          "id": "abc123"
        }
        ```

        - done
        """

        let blocks = OutputCanvasMarkdown.blocks(from: markdown)
        XCTAssertTrue(blocks.contains { block in
            if case .code(let language, let text) = block {
                return language == "text" && text.contains("\"id\": \"abc123\"")
            }
            return false
        })

        XCTAssertFalse(blocks.contains { block in
            if case .plain(let text) = block {
                return text.contains("```")
            }
            return false
        }, "Fence markers must not be rendered as plain text.")
    }
}
