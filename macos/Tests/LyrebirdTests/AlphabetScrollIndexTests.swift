import XCTest

@testable import Lyrebird

/// Pure-logic coverage for the Library A–Z fast-scroll rail (#216). Locks down
/// `AlphabetScrollIndex` — the name → bucket bucketing and the tapped-letter →
/// first-row mapping that `LibraryView.scrollToLetter` turns into a
/// `ScrollViewProxy.scrollTo`. Deliberately `AppModel`-free and View-free,
/// mirroring `TrackSelectionResolverTests` / `LibraryFilterTests`.
final class AlphabetScrollIndexTests: XCTestCase {

    // MARK: - Rail letters

    func testLettersAreHashThenAToZ() {
        let letters = AlphabetScrollIndex.letters
        XCTAssertEqual(letters.count, 27, "Expected '#' + 26 letters")
        XCTAssertEqual(letters.first, "#")
        XCTAssertEqual(letters.last, "Z")
        XCTAssertEqual(letters[1], "A")
        // No gaps or repeats in the A–Z run.
        XCTAssertEqual(Array(letters.dropFirst()), Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    }

    // MARK: - bucket(for:)

    func testBucketUppercasesLeadingLetter() {
        XCTAssertEqual(AlphabetScrollIndex.bucket(for: "Abbey Road"), "A")
        XCTAssertEqual(AlphabetScrollIndex.bucket(for: "zeppelin"), "Z")
    }

    func testBucketIsCaseInsensitive() {
        XCTAssertEqual(
            AlphabetScrollIndex.bucket(for: "the wall"),
            AlphabetScrollIndex.bucket(for: "The Wall")
        )
        XCTAssertEqual(AlphabetScrollIndex.bucket(for: "the wall"), "T")
    }

    func testBucketFoldsDiacriticsToBaseLetter() {
        // Matches localizedCaseInsensitiveCompare collation — accented Latin
        // letters land under their base letter, not in '#'.
        XCTAssertEqual(AlphabetScrollIndex.bucket(for: "Édith Piaf"), "E")
        XCTAssertEqual(AlphabetScrollIndex.bucket(for: "Ángel"), "A")
        XCTAssertEqual(AlphabetScrollIndex.bucket(for: "Über"), "U")
    }

    func testBucketSkipsLeadingWhitespace() {
        XCTAssertEqual(AlphabetScrollIndex.bucket(for: "   Radiohead"), "R")
    }

    func testDigitLeadingNameBucketsToHash() {
        XCTAssertEqual(AlphabetScrollIndex.bucket(for: "2Pac"), "#")
        XCTAssertEqual(AlphabetScrollIndex.bucket(for: "50 Cent"), "#")
        XCTAssertEqual(AlphabetScrollIndex.bucket(for: "1999"), "#")
    }

    func testSymbolLeadingAndNonLatinNameBucketsToHash() {
        XCTAssertEqual(AlphabetScrollIndex.bucket(for: "...And Justice for All"), "#")
        XCTAssertEqual(AlphabetScrollIndex.bucket(for: "中島美嘉"), "#")
    }

    func testEmptyAndWhitespaceOnlyNameBucketsToHash() {
        XCTAssertEqual(AlphabetScrollIndex.bucket(for: ""), "#")
        XCTAssertEqual(AlphabetScrollIndex.bucket(for: "   "), "#")
    }

    // MARK: - presentBuckets(in:)

    func testPresentBucketsReflectsLeadingLetters() {
        let names = ["Abba", "Air", "Beck", "2Pac", "Zappa"]
        XCTAssertEqual(
            AlphabetScrollIndex.presentBuckets(in: names),
            Set<Character>(["A", "B", "#", "Z"])
        )
    }

    func testPresentBucketsEmptyForEmptyInput() {
        XCTAssertTrue(AlphabetScrollIndex.presentBuckets(in: []).isEmpty)
    }

    // MARK: - firstIndex(for:in:)

    /// Sorted ascending the way the Library hands the helper its data.
    private let names = [
        "2Pac",          // 0  → '#'
        "ABBA",          // 1  → 'A'
        "Adele",         // 2  → 'A'
        "Beck",          // 3  → 'B'
        "Coldplay",      // 4  → 'C'
        "Muse",          // 5  → 'M'
        "Radiohead",     // 6  → 'R'
    ]

    func testFirstIndexReturnsFirstRowOfBucket() {
        // Two A's — the topmost wins.
        XCTAssertEqual(AlphabetScrollIndex.firstIndex(for: "A", in: names), 1)
        XCTAssertEqual(AlphabetScrollIndex.firstIndex(for: "B", in: names), 3)
        XCTAssertEqual(AlphabetScrollIndex.firstIndex(for: "R", in: names), 6)
    }

    func testHashBucketResolvesToNonAlphaLeadingRows() {
        XCTAssertEqual(AlphabetScrollIndex.firstIndex(for: "#", in: names), 0)
    }

    func testAbsentLetterFallsForwardToNextPresentBucket() {
        // No 'D'..'L' rows → forward scan from 'D' lands on the next present
        // bucket, 'M' (Muse, index 5).
        XCTAssertEqual(AlphabetScrollIndex.firstIndex(for: "D", in: names), 5)
        // No 'N'..'Q' rows → forward scan lands on 'R' (Radiohead, index 6).
        XCTAssertEqual(AlphabetScrollIndex.firstIndex(for: "N", in: names), 6)
        XCTAssertEqual(AlphabetScrollIndex.firstIndex(for: "Q", in: names), 6)
    }

    func testLetterBeyondLastRowReturnsNil() {
        // Last row is Radiohead ('R'); dragging onto 'S'–'Z' has nothing at or
        // after it, so the caller should no-op rather than scroll bogusly.
        XCTAssertNil(AlphabetScrollIndex.firstIndex(for: "S", in: names))
        XCTAssertNil(AlphabetScrollIndex.firstIndex(for: "Z", in: names))
    }

    func testEmptyListReturnsNilForEveryLetter() {
        for letter in AlphabetScrollIndex.letters {
            XCTAssertNil(AlphabetScrollIndex.firstIndex(for: letter, in: []))
        }
    }

    func testUnknownLetterReturnsNil() {
        // A letter that isn't on the rail (lowercase, multi-char) can't resolve.
        XCTAssertNil(AlphabetScrollIndex.firstIndex(for: "a", in: names))
        XCTAssertNil(AlphabetScrollIndex.firstIndex(for: "1", in: names))
    }

    /// Every present bucket must resolve to an index whose own bucket matches —
    /// i.e. tapping a present letter never lands you in the wrong section.
    func testEveryPresentBucketResolvesToAMatchingRow() {
        for bucket in AlphabetScrollIndex.presentBuckets(in: names) {
            guard let index = AlphabetScrollIndex.firstIndex(for: bucket, in: names) else {
                XCTFail("present bucket \(bucket) resolved to nil")
                continue
            }
            XCTAssertEqual(AlphabetScrollIndex.bucket(for: names[index]), bucket)
        }
    }
}
