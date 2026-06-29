import Foundation

/// One focus-words dictionary entry: a `key` the user may dictate mapped to the `value` that should
/// be written. A plain spelling term (no `:` in the line) becomes an entry whose value mirrors its
/// key, i.e. "spell anything that sounds like this exactly as written".
struct DictionaryEntry: Equatable {
    let key: String
    let value: String
}

/// Deterministic, code-side application of the focus-words dictionary. This deliberately does NOT
/// go through the LLM: a model treats a glossary as a normalization target and over-fires (mapping
/// every name to the nearest entry, or substring-matching a phrase trigger).
///
/// Only **expansion** entries (`key != value`, e.g. "ashwin email : a@b.com") are applied here, as a
/// literal, whole-word, case-insensitive phrase replacement. Bare "ashwin" can't match the phrase
/// "ashwin email", so the replacement is unambiguous and never touches unrelated text.
///
/// **Spelling** entries (`key == value`, e.g. "alecs") are intentionally NOT text-replaced. Mapping a
/// mis-heard word to its intended spelling requires *phonetic* matching, and any text-only phonetic
/// scheme over-fires on ordinary words (Soundex alone maps the everyday word "also" to the same code
/// as "alecs"). Those terms are instead fed to Deepgram as keyterms (see `keys`), so the recognizer —
/// which has the actual audio — biases "alex"→"alecs" without ever clobbering words that merely look
/// similar on paper.
enum FocusWordsDictionary {

    /// Parse the raw focus-words string into `key → value` entries, one per line. A line of the form
    /// "trigger : replacement" becomes a substitution (split on the first colon that isn't part of
    /// "://", so URLs survive); a line with no colon becomes a spelling lock whose value mirrors its
    /// key. Trims whitespace, drops blank lines, and removes case-insensitive duplicate keys.
    static func parseEntries(_ raw: String?) -> [DictionaryEntry] {
        guard let raw else { return [] }
        var seen = Set<String>()
        var entries: [DictionaryEntry] = []
        for line in raw.split(separator: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            let key: String
            let value: String
            if let colon = separatorColonIndex(in: trimmedLine) {
                key = String(trimmedLine[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rhs = String(trimmedLine[trimmedLine.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                value = rhs.isEmpty ? key : rhs
            } else {
                key = trimmedLine
                value = trimmedLine
            }
            guard !key.isEmpty else { continue }
            if seen.insert(key.lowercased()).inserted {
                entries.append(DictionaryEntry(key: key, value: value))
            }
        }
        return entries
    }

    /// The dictionary keys (trigger phrases) — what the user actually says. Fed to Deepgram as
    /// keyterms so recognition is biased toward the spoken triggers, not the written replacements.
    static func keys(_ raw: String?) -> [String] {
        parseEntries(raw).map(\.key)
    }

    /// Apply the dictionary's expansion entries to `text`, returning the corrected string. Longer
    /// keys run first so a longer phrase wins over a shorter overlapping one. Bare spelling terms
    /// (`key == value`) are skipped — they bias recognition via `keys`, not text replacement.
    /// Returns `text` unchanged when there are no expansion entries.
    static func apply(_ raw: String?, to text: String) -> String {
        let entries = parseEntries(raw)
        guard !entries.isEmpty, !text.isEmpty else { return text }

        var result = text
        let expansions = entries
            .filter { $0.key.lowercased() != $0.value.lowercased() }
            .sorted { $0.key.count > $1.key.count }
        for entry in expansions {
            result = replaceExpansion(in: result, key: entry.key, value: entry.value)
        }
        return result
    }

    // MARK: - Expansion (literal whole-phrase replacement)

    private static func replaceExpansion(in text: String, key: String, value: String) -> String {
        let words = key
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return text }
        // Allow any whitespace run between words; require a non-word-character boundary on each side
        // so "ashwin email" matches as a phrase but "ashwin" alone never matches it.
        let pattern = "(?<!\\w)" + words.joined(separator: "\\s+") + "(?!\\w)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        let template = NSRegularExpression.escapedTemplate(for: value)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// Index of the first ":" that separates a trigger from its replacement, skipping any colon
    /// that's part of "://" so a URL (e.g. "https://x.com") survives as a bare term or a value.
    private static func separatorColonIndex(in s: String) -> String.Index? {
        var idx = s.startIndex
        while idx < s.endIndex {
            if s[idx] == ":" {
                let next = s.index(after: idx)
                if next == s.endIndex || s[next] != "/" { return idx }
            }
            idx = s.index(after: idx)
        }
        return nil
    }
}
