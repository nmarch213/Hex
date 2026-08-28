import XCTest
@testable import HexKeyboardTracer

final class PrototypeGlideDecoderTests: XCTestCase {
    func testRepresentativeTemplatePathsRankTheIntendedWordInTopThree() throws {
        let decoder = try makeDecoder()
        let keyCenters = Self.keyCenters
        let words = [
            "hello",
            "there",
            "keyboard",
            "voice",
            "quick",
            "brown",
            "message",
            "today",
            "world",
            "people",
        ]

        for word in words {
            let candidates = decoder.candidates(
                for: Self.path(for: word, keyCenters: keyCenters),
                keyCenters: keyCenters,
                limit: 3
            )
            XCTAssertTrue(
                candidates.map(\.word).contains(word),
                "Expected \(word) in \(candidates.map(\.word))"
            )
            XCTAssertLessThanOrEqual(
                candidates.first?.score ?? .infinity,
                6,
                "Expected \(word) path to clear the commit threshold"
            )
        }
    }

    func testShortMovementDoesNotDecodeAWord() throws {
        let decoder = try makeDecoder()
        let keyCenters = Self.keyCenters
        let start = try XCTUnwrap(keyCenters["t"])
        let path = [
            start,
            PrototypeGlidePoint(x: start.x + 0.1, y: start.y + 0.05),
        ]

        XCTAssertEqual(
            decoder.candidates(for: path, keyCenters: keyCenters),
            []
        )
    }

    func testBundledLexiconContainsExactlyTwentyThousandWords() throws {
        let contents = try lexiconContents()
        let entries = PrototypeGlideLexicon.entries(from: contents)
        let resourceEntryCount = contents
            .split(whereSeparator: { $0.isNewline })
            .filter { $0.first != "#" }
            .count

        XCTAssertEqual(resourceEntryCount, 20_000)
        XCTAssertEqual(entries.count, 19_998)
        XCTAssertEqual(entries.first?.word, "the")
    }

    func testSwipeSettingIsOptInAndSharedThroughDefaults() throws {
        let suiteName = "PrototypeGlideDecoderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(
            PrototypeKeyboardPreferences.isSwipeToTypeEnabled(in: defaults)
        )
        PrototypeKeyboardPreferences.setSwipeToTypeEnabled(true, in: defaults)
        XCTAssertTrue(
            PrototypeKeyboardPreferences.isSwipeToTypeEnabled(in: defaults)
        )
    }

    private func makeDecoder() throws -> PrototypeGlideDecoder {
        PrototypeGlideDecoder(
            entries: PrototypeGlideLexicon.entries(
                from: try lexiconContents()
            )
        )
    }

    private func lexiconContents() throws -> String {
        let bundle = Bundle(for: Self.self)
        let resourceURL = try XCTUnwrap(
            bundle.url(
                forResource: "english-glide-frequency",
                withExtension: "txt"
            )
        )
        return try String(contentsOf: resourceURL, encoding: .utf8)
    }

    private static let keyCenters: [Character: PrototypeGlidePoint] = {
        let rows: [(letters: String, offset: Double)] = [
            ("qwertyuiop", 0),
            ("asdfghjkl", 0.5),
            ("zxcvbnm", 1.5),
        ]
        return Dictionary(uniqueKeysWithValues: rows.enumerated().flatMap { rowIndex, row in
            row.letters.enumerated().map { column, letter in
                (
                    letter,
                    PrototypeGlidePoint(
                        x: Double(column) + row.offset,
                        y: Double(rowIndex)
                    )
                )
            }
        })
    }()

    private static func path(
        for word: String,
        keyCenters: [Character: PrototypeGlidePoint]
    ) -> [PrototypeGlidePoint] {
        let letterCenters = word.reduce(into: [PrototypeGlidePoint]()) {
            points, letter in
            guard let center = keyCenters[letter], points.last != center else {
                return
            }
            points.append(center)
        }

        return letterCenters.enumerated().flatMap { index, point in
            guard index > 0 else { return [point] }
            let previous = letterCenters[index - 1]
            return [0.25, 0.5, 0.75, 1].map { progress in
                PrototypeGlidePoint(
                    x: previous.x + (point.x - previous.x) * progress,
                    y: previous.y + (point.y - previous.y) * progress
                )
            }
        }
    }
}
