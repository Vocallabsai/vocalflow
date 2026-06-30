import XCTest
@testable import VocalFlow

final class TypeOverDetectorTests: XCTestCase {

    private func corrected(_ injected: [String], _ baseline: String, _ current: String) -> String? {
        TypeOverDetector.correction(
            injectedWords: Set(injected.map { $0.lowercased() }),
            baseline: baseline, current: current
        )?.corrected
    }

    // MARK: - Should detect a correction

    func testBasicSpellingFix() {
        XCTAssertEqual(corrected(["tell", "jon", "about", "it"], "tell jon about it", "tell john about it"), "john")
    }

    func testPreservesCorrectedWordCasing() {
        XCTAssertEqual(corrected(["jon"], "hi Jon", "hi John"), "John")
    }

    // Regression: count-based diff must survive repeated words in the field.
    func testCorrectedWordAlreadyPresentElsewhere() {
        XCTAssertEqual(corrected(["ayewsh"], "hi ayush ayewsh", "hi ayush ayush"), "ayush")
    }

    func testInjectedWordRepeatsEditingOneOccurrence() {
        XCTAssertEqual(corrected(["ayewsh"], "ayewsh ayewsh", "ayush ayewsh"), "ayush")
    }

    // MARK: - Should NOT detect

    func testNoChange() {
        XCTAssertNil(corrected(["jon"], "tell jon", "tell jon"))
    }

    func testEditToWordVocalFlowDidNotInject() {
        // "work" wasn't injected → editing it is the user's own text, not a correction.
        XCTAssertNil(corrected(["jon"], "email jon at work", "email jon at home"))
    }

    func testIgnoresCommonHomophone() {
        XCTAssertNil(corrected(["there"], "go there now", "go their now"))
    }

    func testIgnoresTwoWordChange() {
        XCTAssertNil(corrected(["jon", "smith"], "call jon smith", "call john smyth"))
    }

    func testIgnoresUnrelatedReplacement() {
        XCTAssertNil(corrected(["cat"], "the cat", "the dog"))
    }

    func testIgnoresShortWords() {
        XCTAssertNil(corrected(["it"], "go to it", "go to is"))
    }

    // MARK: - Levenshtein

    func testLevenshtein() {
        XCTAssertEqual(TypeOverDetector.levenshtein("jon", "john"), 1)
        XCTAssertEqual(TypeOverDetector.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(TypeOverDetector.levenshtein("same", "same"), 0)
    }
}
