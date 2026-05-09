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

    func testHasAnyStepReflectsAnyEnabledOption() {
        XCTAssertFalse(LLMProcessingOptions(codeMix: nil, fixSpelling: false, fixGrammar: false, targetLanguage: nil).hasAnyStep)
        XCTAssertTrue(LLMProcessingOptions(codeMix: "Hinglish", fixSpelling: false, fixGrammar: false, targetLanguage: nil).hasAnyStep)
        XCTAssertTrue(LLMProcessingOptions(codeMix: nil, fixSpelling: true, fixGrammar: false, targetLanguage: nil).hasAnyStep)
        XCTAssertTrue(LLMProcessingOptions(codeMix: nil, fixSpelling: false, fixGrammar: true, targetLanguage: nil).hasAnyStep)
        XCTAssertTrue(LLMProcessingOptions(codeMix: nil, fixSpelling: false, fixGrammar: false, targetLanguage: "French").hasAnyStep)
    }
}
