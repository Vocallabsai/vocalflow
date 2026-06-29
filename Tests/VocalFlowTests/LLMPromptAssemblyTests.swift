import XCTest
@testable import VocalFlow

final class LLMPromptAssemblyTests: XCTestCase {
    func testReturnsNilWhenNoStepsEnabled() {
        let options = LLMProcessingOptions(
            codeMix: nil,
            fixSpelling: false,
            fixGrammar: false,
            targetLanguage: nil
        )
        XCTAssertNil(LLMService.buildSystemPrompt(for: options))
    }

    func testSpellingOnlyProducesSingleStep() {
        let options = LLMProcessingOptions(
            codeMix: nil,
            fixSpelling: true,
            fixGrammar: false,
            targetLanguage: nil
        )
        let expected = """
        Process the following text by applying these steps in order:
        1. Fix any spelling mistakes. Do not change meaning or structure.

        Return only the final processed text with no explanation.
        """
        XCTAssertEqual(LLMService.buildSystemPrompt(for: options), expected)
    }

    func testSpellingAndHinglishProduceTwoNumberedSteps() {
        let options = LLMProcessingOptions(
            codeMix: "Hinglish",
            fixSpelling: true,
            fixGrammar: false,
            targetLanguage: nil
        )
        let prompt = LLMService.buildSystemPrompt(for: options)
        XCTAssertNotNil(prompt)
        let lines = prompt!.split(separator: "\n").map(String.init)
        // Header + 2 steps + footer = 4 lines
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.first, "Process the following text by applying these steps in order:")
        XCTAssertTrue(lines[1].hasPrefix("1. The input is in Hinglish."))
        XCTAssertTrue(lines[2].hasPrefix("2. Fix any spelling mistakes."))
        XCTAssertEqual(lines.last, "Return only the final processed text with no explanation.")
    }

    func testAllStepsAreNumberedSequentially() {
        let options = LLMProcessingOptions(
            codeMix: "Hinglish",
            fixSpelling: true,
            fixGrammar: true,
            targetLanguage: "French"
        )
        let prompt = LLMService.buildSystemPrompt(for: options)
        XCTAssertNotNil(prompt)
        let lines = prompt!.split(separator: "\n").map(String.init)
        // Header + 4 steps + footer = 6 lines
        XCTAssertEqual(lines.count, 6)
        XCTAssertTrue(lines[1].hasPrefix("1. "))
        XCTAssertTrue(lines[2].hasPrefix("2. "))
        XCTAssertTrue(lines[3].hasPrefix("3. "))
        XCTAssertTrue(lines[4].hasPrefix("4. "))
        XCTAssertTrue(lines[4].contains("Translate the entire text to French"))
    }

    func testTranslationOnlyIsNumberedFromOne() {
        let options = LLMProcessingOptions(
            codeMix: nil,
            fixSpelling: false,
            fixGrammar: false,
            targetLanguage: "Spanish"
        )
        let prompt = LLMService.buildSystemPrompt(for: options)
        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt!.contains("1. Translate the entire text to Spanish"))
    }

    func testStepOrderIsCodeMixThenSpellingThenGrammarThenTranslate() {
        let options = LLMProcessingOptions(
            codeMix: "Tanglish",
            fixSpelling: true,
            fixGrammar: true,
            targetLanguage: "English"
        )
        let prompt = LLMService.buildSystemPrompt(for: options)!
        let codeMixIdx = prompt.range(of: "Tanglish")!.lowerBound
        let spellingIdx = prompt.range(of: "spelling")!.lowerBound
        let grammarIdx = prompt.range(of: "grammar")!.lowerBound
        let translateIdx = prompt.range(of: "Translate")!.lowerBound
        XCTAssertLessThan(codeMixIdx, spellingIdx)
        XCTAssertLessThan(spellingIdx, grammarIdx)
        XCTAssertLessThan(grammarIdx, translateIdx)
    }

    func testStripReasoningRemovesThinkBlock() {
        let input = "<think>let me think about this</think>Hi, kyā kar rahe ho?"
        XCTAssertEqual(LLMService.stripReasoning(input), "Hi, kyā kar rahe ho?")
    }

    func testStripReasoningRemovesMultilineThinkingBlock() {
        let input = """
        <thinking>
        Step 1: parse
        Step 2: respond
        </thinking>
        Final answer.
        """
        XCTAssertEqual(LLMService.stripReasoning(input), "Final answer.")
    }

    func testStripReasoningRemovesReasoningBlock() {
        let input = "<reasoning>internal</reasoning>\n\nOutput text"
        XCTAssertEqual(LLMService.stripReasoning(input), "Output text")
    }

    func testStripReasoningIsCaseInsensitive() {
        let input = "<Think>x</THINK>y"
        XCTAssertEqual(LLMService.stripReasoning(input), "y")
    }

    func testStripReasoningHandlesUnclosedOpener() {
        let input = "<think>only opening tag, no close, final answer here"
        XCTAssertEqual(LLMService.stripReasoning(input), "only opening tag, no close, final answer here".replacingOccurrences(of: "<think>", with: ""))
    }

    func testStripReasoningLeavesCleanTextUntouched() {
        let input = "Hello world."
        XCTAssertEqual(LLMService.stripReasoning(input), "Hello world.")
    }

    func testStripReasoningHandlesMultipleBlocks() {
        let input = "<think>a</think>middle<think>b</think>end"
        XCTAssertEqual(LLMService.stripReasoning(input), "middleend")
    }

    // The focus-words dictionary is applied deterministically in code (FocusWordsDictionary),
    // never through the LLM, so it must NOT appear in the system prompt or trigger an LLM call.

    func testDictionaryIsNeverInjectedIntoTheLLMPrompt() {
        // Even alongside an enabled step, no dictionary text leaks into the prompt.
        let options = LLMProcessingOptions(
            codeMix: nil, fixSpelling: true, fixGrammar: false, targetLanguage: nil, customPrompt: nil)
        let prompt = LLMService.buildSystemPrompt(for: options)!
        XCTAssertFalse(prompt.contains("dictionary"))
        XCTAssertFalse(prompt.contains("trigger"))
        XCTAssertFalse(prompt.contains("→"))
    }

    func testHasAnyStepIgnoresDictionary() {
        // A dictionary-only config has no LLM step (the dictionary is applied in code instead).
        let options = LLMProcessingOptions(
            codeMix: nil, fixSpelling: false, fixGrammar: false, targetLanguage: nil, customPrompt: nil)
        XCTAssertFalse(options.hasAnyStep)
    }

    func testHasAnyStepReflectsAnyEnabledOption() {
        XCTAssertFalse(LLMProcessingOptions(codeMix: nil, fixSpelling: false, fixGrammar: false, targetLanguage: nil).hasAnyStep)
        XCTAssertTrue(LLMProcessingOptions(codeMix: "Hinglish", fixSpelling: false, fixGrammar: false, targetLanguage: nil).hasAnyStep)
        XCTAssertTrue(LLMProcessingOptions(codeMix: nil, fixSpelling: true, fixGrammar: false, targetLanguage: nil).hasAnyStep)
        XCTAssertTrue(LLMProcessingOptions(codeMix: nil, fixSpelling: false, fixGrammar: true, targetLanguage: nil).hasAnyStep)
        XCTAssertTrue(LLMProcessingOptions(codeMix: nil, fixSpelling: false, fixGrammar: false, targetLanguage: "French").hasAnyStep)
    }
}
