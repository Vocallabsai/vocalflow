import Foundation
import ApplicationServices

/// Pure, testable logic for spotting a "type-over" spelling correction: a word
/// VocalFlow injected that the user then edited in place into a close variant.
enum TypeOverDetector {

    /// Common words we never auto-learn — biasing Deepgram toward them (or toward
    /// one side of a homophone like there/their) would hurt recognition. Focus
    /// words are meant for names / jargon / out-of-vocabulary terms.
    static let commonWords: Set<String> = [
        "the","and","that","have","for","not","with","you","this","but","his","from","they",
        "say","her","she","will","one","all","would","there","their","they're","what","out","about",
        "who","get","which","when","make","can","like","time","just","him","know","take","into","your",
        "you're","year","good","some","could","them","see","other","than","then","now","look","only",
        "come","its","it's","over","think","also","back","after","use","two","too","to","how","our",
        "work","first","well","way","even","new","want","because","any","these","give","day","most",
        "here","hear","were","where","we're","been","being","are","our","off","of","on","in","is","as",
    ]

    /// Detect a single-word in-place correction. `injectedWords` are the (lowercased)
    /// words VocalFlow just typed; `baseline` is the field right after injection;
    /// `current` is the field after the user edited it.
    static func correction(injectedWords: Set<String>, baseline: String, current: String) -> (original: String, corrected: String)? {
        let baseTokens = tokenize(baseline)
        let curTokens  = tokenize(current)

        // Count-based diff: how each word's occurrence count changed. Using counts
        // (not set membership) means it still works when a word repeats in the field
        // or when the corrected spelling already appears elsewhere.
        var delta: [String: Int] = [:]
        for w in baseTokens { delta[w.lowercased(), default: 0] -= 1 }
        for w in curTokens  { delta[w.lowercased(), default: 0] += 1 }

        let gained = delta.filter { $0.value > 0 }   // appears more now → the new spelling
        let lost   = delta.filter { $0.value < 0 }   // appears less now → the old spelling
        // Exactly one word swapped for exactly one other (each by a single occurrence).
        guard gained.count == 1, lost.count == 1,
              let added = gained.first, added.value == 1,
              let removed = lost.first, removed.value == -1 else { return nil }

        let originalLC = removed.key
        let correctedLC = added.key
        // The word that lost an occurrence must be one VocalFlow injected.
        guard injectedWords.contains(originalLC) else { return nil }

        // The change must be a spelling variant, not an unrelated word…
        let dist = levenshtein(originalLC, correctedLC)
        let maxLen = max(originalLC.count, correctedLC.count)
        guard maxLen >= 3, dist >= 1, dist <= max(2, maxLen / 3) else { return nil }
        // …and not an everyday word.
        guard !commonWords.contains(correctedLC) else { return nil }

        // Preserve the words' real casing as they appear in the text.
        let original  = baseTokens.first { $0.lowercased() == originalLC } ?? originalLC
        let corrected = curTokens.first  { $0.lowercased() == correctedLC } ?? correctedLC
        return (original, corrected)
    }

    static func tokenize(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { $0.contains(where: { $0.isLetter }) }
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

/// C callback bridge — recovers the watcher from the refcon (it can't capture context).
private let axValueChangedCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    Unmanaged<TypeOverWatcher>.fromOpaque(refcon).takeUnretainedValue().valueChanged()
}

/// Watches the focused text field (via Accessibility) for a short window after
/// VocalFlow injects text, and reports an in-place spelling correction of an
/// injected word. Privacy: it only diffs against what was injected and keeps just
/// the wrong→right word pair — it never stores the surrounding field text.
final class TypeOverWatcher {

    /// Called on the main thread once the user has *finished* editing a word into
    /// its corrected spelling. `original` is the word that was typed and corrected
    /// away from, so the caller can drop it and its near-variants from the
    /// dictionary — collapsing successive re-spellings of the same word.
    var onCorrection: ((_ corrected: String, _ original: String) -> Void)?

    private var observer: AXObserver?
    private var element: AXUIElement?
    private var baseline = ""
    private var injectedWords: Set<String> = []
    private var stopWork: DispatchWorkItem?
    private var debounceWork: DispatchWorkItem?
    /// The word we've already auto-added this session — so further edits update it.
    private var lastLearned: String?
    private let watchSeconds: TimeInterval = 120
    /// How long the field must be idle before we treat an edit as finished.
    private let settleSeconds: TimeInterval = 2.0

    /// Begin watching after `injected` was typed into the focused field. The
    /// baseline snapshot is deferred briefly so the paste has settled.
    func watch(injected: String) {
        let words = Set(TypeOverDetector.tokenize(injected).map { $0.lowercased() })
        guard !words.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.start(injectedWords: words)
        }
    }

    private func start(injectedWords words: Set<String>) {
        stop()
        guard AXIsProcessTrusted() else { return }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return }
        let el = focused as! AXUIElement

        guard let value = stringValue(of: el) else { return }   // field must expose its text
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success else { return }

        var obs: AXObserver?
        guard AXObserverCreate(pid, axValueChangedCallback, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, el, kAXValueChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)

        self.observer = obs
        self.element = el
        self.baseline = value
        self.injectedWords = words

        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + watchSeconds, execute: work)
    }

    /// Fires on every keystroke — we don't act yet. Instead we (re)arm a settle
    /// timer, so we only evaluate once the user pauses. Each new keystroke pushes
    /// the timer out, so mid-word states like "Aysh" never get learned.
    fileprivate func valueChanged() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds, execute: work)
    }

    /// Run after editing settles: learn the *final* spelling. If we already learned
    /// a (now-superseded) word this session, ask the caller to replace it.
    private func evaluate() {
        guard let el = element, let current = stringValue(of: el) else { return }
        guard let (original, corrected) = TypeOverDetector.correction(
            injectedWords: injectedWords, baseline: baseline, current: current
        ) else { return }
        guard corrected.lowercased() != lastLearned?.lowercased() else { return }
        lastLearned = corrected
        onCorrection?(corrected, original)
    }

    func stop() {
        stopWork?.cancel(); stopWork = nil
        debounceWork?.cancel(); debounceWork = nil
        if let obs = observer, let el = element {
            AXObserverRemoveNotification(obs, el, kAXValueChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        element = nil
        baseline = ""
        injectedWords = []
        lastLearned = nil
    }

    private func stringValue(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
