import Foundation

enum PrototypeTranscriptPipeline {
    static func apply(
        _ text: String,
        removeFillerWords: Bool,
        spokenPunctuation: Bool,
        lowercase: Bool,
        removePunctuation: Bool
    ) -> String {
        var output = text

        if removeFillerWords {
            output = WordRemovalApplier.apply(
                output,
                removals: ["um+", "uh+", "erm+", "hmm+"].map { WordRemoval(pattern: $0) }
            )
        }

        if spokenPunctuation {
            output = WordRemappingApplier.apply(
                output,
                remappings: [
                    WordRemapping(match: "comma", replacement: ","),
                    WordRemapping(match: "period", replacement: "."),
                    WordRemapping(match: "full stop", replacement: "."),
                    WordRemapping(match: "question mark", replacement: "?"),
                    WordRemapping(match: "exclamation point", replacement: "!"),
                    WordRemapping(match: "new line", replacement: "\\n"),
                    WordRemapping(match: "new paragraph", replacement: "\\n\\n"),
                    WordRemapping(match: "tab", replacement: "\\t"),
                ]
            )
        }

        return TranscriptFormattingApplier.apply(
            output,
            lowercase: lowercase,
            removePunctuation: removePunctuation
        )
    }
}
