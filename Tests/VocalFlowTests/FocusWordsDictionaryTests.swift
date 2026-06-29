import XCTest
@testable import VocalFlow

final class FocusWordsDictionaryTests: XCTestCase {

    // MARK: - Parsing

    func testParseMapsKeysToValuesAndDeduplicates() {
        let entries = FocusWordsDictionary.parseEntries(
            "ashwin email : ashwin.ganapathy78@gmail.com\nalecs\nAshwin Email : other@x.com")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0], DictionaryEntry(key: "ashwin email", value: "ashwin.ganapathy78@gmail.com"))
        // No colon → value mirrors the key (spelling lock).
        XCTAssertEqual(entries[1], DictionaryEntry(key: "alecs", value: "alecs"))
    }

    func testParseKeepsColonsInsideValue() {
        XCTAssertEqual(
            FocusWordsDictionary.parseEntries("site : https://example.com"),
            [DictionaryEntry(key: "site", value: "https://example.com")])
    }

    func testBareUrlStaysASingleTermNotSplitAtScheme() {
        XCTAssertEqual(
            FocusWordsDictionary.parseEntries("https://example.com"),
            [DictionaryEntry(key: "https://example.com", value: "https://example.com")])
    }

    func testKeysReturnsTriggerPhrasesForKeyterms() {
        XCTAssertEqual(
            FocusWordsDictionary.keys("ashwin email : x@y.com\nalecs"),
            ["ashwin email", "alecs"])
    }

    // MARK: - Expansion (literal whole-phrase replacement)

    func testExpansionFiresOnWholePhrase() {
        let out = FocusWordsDictionary.apply(
            "ashwin email : johndoe@gmail.com", to: "please send it to my ashwin email today")
        XCTAssertEqual(out, "please send it to my johndoe@gmail.com today")
    }

    func testExpansionDoesNotFireOnBareSubword() {
        // The reported bug: saying just the name must NOT expand to the email.
        let out = FocusWordsDictionary.apply(
            "ashwin email : johndoe@gmail.com", to: "hi my name is ashwin")
        XCTAssertEqual(out, "hi my name is ashwin")
    }

    func testExpansionIsCaseInsensitiveAndPreservesReplacementVerbatim() {
        let out = FocusWordsDictionary.apply(
            "ashwin email : johndoe@gmail.com", to: "Ashwin Email please")
        XCTAssertEqual(out, "johndoe@gmail.com please")
    }

    func testLongerExpansionWinsOverShorterOverlap() {
        let dict = "ashwin : Ashwin Ganapathy\nashwin email : johndoe@gmail.com"
        XCTAssertEqual(
            FocusWordsDictionary.apply(dict, to: "my ashwin email"),
            "my johndoe@gmail.com")
        XCTAssertEqual(
            FocusWordsDictionary.apply(dict, to: "hi ashwin"),
            "hi Ashwin Ganapathy")
    }

    // MARK: - Bare spelling terms are NOT text-replaced (recognition-only via keyterms)

    func testBareTermDoesNotTextReplaceSimilarLookingWords() {
        // A bare term must never clobber ordinary words that merely look/sound similar on paper —
        // this is the whole reason the phonetic text pass was removed (it mapped "also" → "alecs").
        XCTAssertEqual(FocusWordsDictionary.apply("alecs", to: "I also think alex left"),
                       "I also think alex left")
        XCTAssertEqual(FocusWordsDictionary.apply("alecs", to: "tell david hello"),
                       "tell david hello")
    }

    func testBareTermStillContributesAKeyterm() {
        // It does nothing in `apply`, but it must still bias recognition via `keys`.
        XCTAssertEqual(FocusWordsDictionary.keys("alecs"), ["alecs"])
    }

    func testEmptyDictionaryLeavesTextUnchanged() {
        XCTAssertEqual(FocusWordsDictionary.apply("   \n\n  ", to: "nothing changes here"), "nothing changes here")
    }

    func testTextWithNoMatchesIsUnchanged() {
        XCTAssertEqual(
            FocusWordsDictionary.apply("alecs\nashwin email : x@y.com", to: "the quick brown fox"),
            "the quick brown fox")
    }
}
