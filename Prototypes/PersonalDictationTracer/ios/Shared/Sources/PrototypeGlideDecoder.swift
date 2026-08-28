import Foundation

struct PrototypeGlidePoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    func distance(to other: Self) -> Double {
        let deltaX = x - other.x
        let deltaY = y - other.y
        return (deltaX * deltaX + deltaY * deltaY).squareRoot()
    }
}

struct PrototypeGlideLexiconEntry: Equatable, Sendable {
    let word: String
    let frequency: Int64
    let rank: Int
    fileprivate let pathLetters: [Character]

    init(word: String, frequency: Int64, rank: Int) {
        self.word = word
        self.frequency = frequency
        self.rank = rank
        self.pathLetters = word.filter({ $0.isASCIILowercase }).reduce(into: []) { letters, letter in
            if letters.last != letter {
                letters.append(letter)
            }
        }
    }
}

struct PrototypeGlideCandidate: Equatable, Sendable {
    let word: String
    let score: Double
}

enum PrototypeGlideLexicon {
    static func entries(from contents: String, limit: Int = 20_000) -> [PrototypeGlideLexiconEntry] {
        var entries: [PrototypeGlideLexiconEntry] = []
        entries.reserveCapacity(limit)

        for line in contents.split(whereSeparator: { $0.isNewline }) {
            guard entries.count < limit else { break }
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard let first = fields.first else { continue }

            let word = first.lowercased()
            guard word.count >= 2,
                  word.first?.isASCIILowercase == true,
                  word.last?.isASCIILowercase == true,
                  word.allSatisfy({ character in
                      character.isASCIILowercase || character == "'"
                  }) else {
                continue
            }

            let frequency = fields.count > 1
                ? Int64(fields[1]) ?? 1
                : 1
            entries.append(
                PrototypeGlideLexiconEntry(
                    word: word,
                    frequency: frequency,
                    rank: entries.count + 1
                )
            )
        }
        return entries
    }
}

private extension Character {
    var isASCIILowercase: Bool {
        unicodeScalars.count == 1
            && unicodeScalars.first.map { scalar in
                scalar.value >= 97 && scalar.value <= 122
            } == true
    }
}

struct PrototypeGlideDecoder: Sendable {
    private struct Endpoint: Hashable, Sendable {
        let first: Character
        let last: Character
    }

    private let entriesByEndpoint: [Endpoint: [PrototypeGlideLexiconEntry]]
    private let maximumRank: Double

    init(entries: [PrototypeGlideLexiconEntry]) {
        let usableEntries = entries.filter { $0.pathLetters.isEmpty == false }
        self.entriesByEndpoint = Dictionary(grouping: usableEntries) { entry in
            Endpoint(
                first: entry.pathLetters[0],
                last: entry.pathLetters[entry.pathLetters.count - 1]
            )
        }
        self.maximumRank = Double(
            max(usableEntries.map(\.rank).max() ?? 0, 1)
        )
    }

    func candidates(
        for rawPath: [PrototypeGlidePoint],
        keyCenters: [Character: PrototypeGlidePoint],
        limit: Int = 3
    ) -> [PrototypeGlideCandidate] {
        guard rawPath.count >= 2,
              entriesByEndpoint.isEmpty == false,
              limit > 0,
              let keySpacing = averageKeySpacing(in: keyCenters) else {
            return []
        }

        let path = simplified(rawPath, minimumDistance: keySpacing * 0.12)
        guard pathLength(path) >= keySpacing * 0.7 else { return [] }

        let signature = nearestKeySignature(for: path, keyCenters: keyCenters)
        let sampledPath = resampled(path, count: 28)
        guard signature.count >= 2, sampledPath.count == 28 else { return [] }

        let possibleStarts = nearbyKeys(
            to: path[0],
            keyCenters: keyCenters,
            maximumDistance: keySpacing * 0.85
        )
        let possibleEnds = nearbyKeys(
            to: path[path.count - 1],
            keyCenters: keyCenters,
            maximumDistance: keySpacing * 0.85
        )
        let endpointEntries = possibleStarts.flatMap { first in
            possibleEnds.flatMap { last in
                entriesByEndpoint[Endpoint(first: first, last: last)] ?? []
            }
        }

        var ranked: [PrototypeGlideCandidate] = []
        ranked.reserveCapacity(64)

        for entry in endpointEntries {
            let letters = entry.pathLetters
            guard letters.count >= 2,
                  let first = letters.first.flatMap({ keyCenters[$0] }),
                  let last = letters.last.flatMap({ keyCenters[$0] }) else {
                continue
            }

            let endpointDistance = (
                path[0].distance(to: first)
                    + path[path.count - 1].distance(to: last)
            ) / keySpacing
            guard endpointDistance <= 2.4 else { continue }

            let template = letters.compactMap { keyCenters[$0] }
            guard template.count == letters.count else { continue }
            let sampledTemplate = resampled(template, count: sampledPath.count)
            guard sampledTemplate.count == sampledPath.count else { continue }

            let shapeDistance = zip(sampledPath, sampledTemplate).reduce(0.0) { total, pair in
                total + pair.0.distance(to: pair.1) / keySpacing
            } / Double(sampledPath.count)
            let sequenceDistance = Double(editDistance(signature, letters))
                / Double(max(signature.count, letters.count))
            let frequencyPenalty = log1p(Double(entry.rank)) / log1p(maximumRank)
            let score = endpointDistance * 2.8
                + shapeDistance * 1.8
                + sequenceDistance * 1.5
                + frequencyPenalty * 0.28

            ranked.append(PrototypeGlideCandidate(word: entry.word, score: score))
        }

        return ranked
            .sorted { left, right in
                if abs(left.score - right.score) < 0.000_001 {
                    return left.word < right.word
                }
                return left.score < right.score
            }
            .prefix(limit)
            .map { $0 }
    }

    func nearestKeySignature(
        for path: [PrototypeGlidePoint],
        keyCenters: [Character: PrototypeGlidePoint]
    ) -> [Character] {
        path.reduce(into: []) { signature, point in
            guard let nearest = keyCenters.min(by: { left, right in
                left.value.distance(to: point) < right.value.distance(to: point)
            })?.key,
            signature.last != nearest else {
                return
            }
            signature.append(nearest)
        }
    }

    private func averageKeySpacing(
        in keyCenters: [Character: PrototypeGlidePoint]
    ) -> Double? {
        let rows = [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")]
        let distances = rows.flatMap { row in
            zip(row, row.dropFirst()).compactMap { left, right -> Double? in
                guard let leftCenter = keyCenters[left],
                      let rightCenter = keyCenters[right] else {
                    return nil
                }
                return leftCenter.distance(to: rightCenter)
            }
        }
        guard distances.isEmpty == false else { return nil }
        return distances.reduce(0, +) / Double(distances.count)
    }

    private func nearbyKeys(
        to point: PrototypeGlidePoint,
        keyCenters: [Character: PrototypeGlidePoint],
        maximumDistance: Double
    ) -> [Character] {
        keyCenters.compactMap { letter, center in
            center.distance(to: point) <= maximumDistance ? letter : nil
        }
    }

    private func simplified(
        _ path: [PrototypeGlidePoint],
        minimumDistance: Double
    ) -> [PrototypeGlidePoint] {
        guard let first = path.first else { return [] }
        var result = [first]
        for point in path.dropFirst() where point.distance(to: result[result.count - 1]) >= minimumDistance {
            result.append(point)
        }
        if let last = path.last, result.last != last {
            result.append(last)
        }
        return result
    }

    private func pathLength(_ path: [PrototypeGlidePoint]) -> Double {
        zip(path, path.dropFirst()).reduce(0) { total, pair in
            total + pair.0.distance(to: pair.1)
        }
    }

    private func resampled(
        _ path: [PrototypeGlidePoint],
        count: Int
    ) -> [PrototypeGlidePoint] {
        guard count > 1, path.count > 1 else { return path }
        let totalLength = pathLength(path)
        guard totalLength > 0 else {
            return Array(repeating: path[0], count: count)
        }

        let step = totalLength / Double(count - 1)
        var result = [path[0]]
        var remaining = step
        var previous = path[0]
        var index = 1

        while index < path.count, result.count < count {
            let current = path[index]
            let segmentLength = previous.distance(to: current)
            if segmentLength >= remaining {
                let ratio = remaining / max(segmentLength, 0.000_001)
                let interpolated = PrototypeGlidePoint(
                    x: previous.x + (current.x - previous.x) * ratio,
                    y: previous.y + (current.y - previous.y) * ratio
                )
                result.append(interpolated)
                previous = interpolated
                remaining = step
            } else {
                remaining -= segmentLength
                previous = current
                index += 1
            }
        }

        while result.count < count {
            result.append(path[path.count - 1])
        }
        return result
    }

    private func editDistance(_ left: [Character], _ right: [Character]) -> Int {
        var row = Array(0...right.count)
        for leftIndex in left.indices {
            var diagonal = row[0]
            row[0] = left.distance(from: left.startIndex, to: leftIndex) + 1
            for rightOffset in right.indices {
                let column = right.distance(from: right.startIndex, to: rightOffset) + 1
                let above = row[column]
                row[column] = min(
                    row[column] + 1,
                    row[column - 1] + 1,
                    diagonal + (left[leftIndex] == right[rightOffset] ? 0 : 1)
                )
                diagonal = above
            }
        }
        return row[right.count]
    }
}
