import AppKit
import ApplicationServices
import AiGrammarCore

/// The live correction pipeline: composer changes → debounce → spellcheck → act.
///
/// - High-confidence typos are autocorrected once the word is COMPLETE (a boundary follows), so we
///   never rewrite a word mid-type. Each autocorrect records an undoable `Correction`.
/// - Everything else surfaces as a suggestion popover near the word.
/// - Our own writes are suppressed from re-triggering the pipeline, and undone/ignored words are
///   remembered for the session so corrections don't fight the user.
final class ComposerPipeline {
    private let monitor: FocusMonitor
    private let settings: Settings
    private let spell = SpellEngine()
    private let aiChecker: AISpellChecker

    private var debounce: DispatchWorkItem?
    private var suppressUntil = Date.distantPast
    private var ignored = Set<String>()          // lowercased words to stop correcting this session
    private var reviewSkipped = Set<String>()    // words skipped during the current review only
    private(set) var corrections: [Correction] = []
    private var reviewing = false                // stepping through issues from a manual ⌃⌘C check

    // AI spell check (supplements the dictionary): async results cached against the text they came
    // from, merged into the issue list only while the composer still holds that exact text.
    private var aiDebounce: DispatchWorkItem?
    private var aiTask: Task<Void, Never>?
    private var aiIssues: [SpellIssue] = []
    private var aiIssuesText = ""
    private var lastText = ""                     // to detect a just-completed word for "perword"

    /// (issue, screen bounds of the word, composer element) — show a suggestion popover.
    var onSuggestion: ((SpellIssue, CGRect?) -> Void)?
    /// (correction, screen bounds of the corrected word) — show an undo chip.
    var onAutocorrect: ((Correction, CGRect?) -> Void)?
    /// Composer lost focus / cleared — dismiss any transient UI.
    var onDismissUI: (() -> Void)?
    /// Number of outstanding spelling issues — drives the menu-bar count badge (red N / green ✓).
    var onIssueCount: ((Int) -> Void)?

    init(monitor: FocusMonitor, settings: Settings, aiChecker: AISpellChecker) {
        self.monitor = monitor
        self.settings = settings
        self.aiChecker = aiChecker
        monitor.onComposerValueChanged = { [weak self] in self?.scheduleProcess() }
        monitor.onComposerUnfocused = { [weak self] in
            self?.endReview()
            self?.aiIssues = []            // don't carry stale AI results to another composer
            self?.aiIssuesText = ""
            self?.onDismissUI?()
            self?.onIssueCount?(0)
        }
    }

    // MARK: Scheduling

    private func scheduleProcess() {
        if Date() < suppressUntil { return }     // ignore the echo of our own edit
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.process() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)

        // Schedule an AI check per its own cadence (independent of the fast dictionary debounce).
        if settings.aiSpellEnabled, !settings.aiSpellModel.isEmpty,
           let el = monitor.lastSlackElement,
           let text = AX.string(el, kAXValueAttribute as String) {
            let boundary = boundaryJustCompleted(old: lastText, new: text)
            lastText = text
            scheduleAICheck(text: text, boundaryCompleted: boundary)
        }
    }

    /// True when the user just finished a word — the text grew and now ends in a space/punctuation.
    private func boundaryJustCompleted(old: String, new: String) -> Bool {
        guard new.count > old.count, let last = new.unicodeScalars.last else { return false }
        return CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains(last)
    }

    /// Kick an AI spell check on `text` according to the chosen cadence. On-demand does nothing here
    /// (it runs from `checkNow`). Results merge into the badge/review when they return.
    private func scheduleAICheck(text: String, boundaryCompleted: Bool) {
        switch settings.aiSpellCadence {
        case "ondemand":
            return
        case "perword":
            guard boundaryCompleted else { return }
            aiDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.runAICheck(text: text) }
            aiDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        default:  // "delayed"
            aiDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.runAICheck(text: text) }
            aiDebounce = work
            let delay = Double(max(200, settings.aiSpellDelayMs)) / 1000.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func runAICheck(text: String) {
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            guard let self else { return }
            let issues = await self.aiChecker.check(text, modelId: self.settings.aiSpellModel)
            if Task.isCancelled { return }   // superseded — don't overwrite newer results
            await MainActor.run {
                // Only apply if the composer still holds exactly what we checked.
                guard let el = self.monitor.lastSlackElement,
                      AX.string(el, kAXValueAttribute as String) == text else { return }
                self.aiIssues = issues
                self.aiIssuesText = text
                let count = self.mergedIssues(in: text).count
                self.onIssueCount?(self.settings.suggestionsEnabled ? count : 0)
                if self.reviewing { self.showNextReviewIssue() }
            }
        }
    }

    /// AI issues take precedence, plus any dictionary issues that don't overlap one. The AI words are
    /// RE-LOCATED against the current text every call, so applying one correction (which changes the
    /// text) doesn't discard the remaining AI suggestions — a fixed word just stops being found.
    private func mergedIssues(in text: String) -> [SpellIssue] {
        var claimed: [NSRange] = []
        // AI first so its context-aware suggestion wins over the dictionary's context-free guess
        // for the same word (e.g. AI "wong→wrong" beats dictionary "wong→song").
        var all = relocate(aiIssues, in: text, claimed: &claimed)
        for d in spell.issues(in: text) where !claimed.contains(where: {
            NSIntersectionRange($0, d.range).length > 0
        }) {
            all.append(d)
            claimed.append(d.range)
        }
        return all.filter { !ignored.contains($0.word.lowercased()) }
                  .sorted { $0.range.location < $1.range.location }
    }

    /// Find each cached AI issue's word/span in the current text (whole-word, non-overlapping), so
    /// its suggestion survives edits made earlier in the same review.
    private func relocate(_ issues: [SpellIssue], in text: String, claimed: inout [NSRange]) -> [SpellIssue] {
        let ns = text as NSString
        var out: [SpellIssue] = []
        for issue in issues {
            var from = 0
            while from <= ns.length {
                let found = ns.range(of: issue.word, options: [],
                                     range: NSRange(location: from, length: ns.length - from))
                if found.location == NSNotFound { break }
                if !claimed.contains(where: { NSIntersectionRange($0, found).length > 0 }),
                   isWholeWord(found, in: ns) {
                    claimed.append(found)
                    out.append(SpellIssue(range: found, word: issue.word,
                                          guesses: issue.guesses, disposition: .suggest))
                    break
                }
                from = found.location + max(found.length, 1)
            }
        }
        return out
    }

    private func isWholeWord(_ range: NSRange, in ns: NSString) -> Bool {
        let letters = CharacterSet.alphanumerics
        if range.location > 0,
           ns.substring(with: NSRange(location: range.location - 1, length: 1))
            .rangeOfCharacter(from: letters) != nil { return false }
        let end = range.location + range.length
        if end < ns.length,
           ns.substring(with: NSRange(location: end, length: 1))
            .rangeOfCharacter(from: letters) != nil { return false }
        return true
    }

    private func suppress(_ seconds: TimeInterval = 0.6) {
        suppressUntil = Date().addingTimeInterval(seconds)
    }

    /// Force an immediate spellcheck pass (from the ⌃⌥G shortcut or the menu), bypassing the
    /// debounce and any write-suppression window.
    func checkNow() {
        Log.write("[check] checkNow() called — spell check running")
        debounce?.cancel()
        suppressUntil = .distantPast
        // Menu-triggered checks make US frontmost (so `snapshot.isSlack` is false); a shortcut can
        // fire before the 0.5s poll refreshes the snapshot. So don't gate the manual path on the
        // live focus — target the last-known Slack composer directly (re-acquiring if possible).
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let acquired = monitor.acquireSlackComposer()
        Log.write("[check] frontmost app=\(frontmost); acquireSlackComposer=\(acquired); "
                + "lastSlackElement=\(monitor.lastSlackElement != nil ? "present" : "nil")")
        guard let element = monitor.lastSlackElement else {
            Log.write("[check] ABORT: no Slack composer known — click into Slack's message box once first")
            onDismissUI?()
            return
        }
        process(element: element, manual: true)
    }

    // MARK: Processing

    private func process() {
        guard monitor.snapshot.isSlack, let element = monitor.lastSlackElement else {
            onDismissUI?(); return
        }
        process(element: element, manual: false)
    }

    private func process(element: AXUIElement, manual: Bool) {
        guard let text = AX.string(element, kAXValueAttribute as String), !text.isEmpty else {
            if manual { Log.write("[check] composer text is EMPTY (nothing to check)") }
            onIssueCount?(0)
            onDismissUI?(); return
        }
        if manual {
            // On-demand: run the AI check first (if on), then step through the merged results.
            if settings.aiSpellEnabled, !settings.aiSpellModel.isEmpty {
                Log.write("[check] running AI spell check (\(settings.aiSpellModel))…")
                aiTask?.cancel()
                aiTask = Task { [weak self] in
                    guard let self else { return }
                    let ai = await self.aiChecker.check(text, modelId: self.settings.aiSpellModel)
                    await MainActor.run {
                        if AX.string(element, kAXValueAttribute as String) == text {
                            self.aiIssues = ai; self.aiIssuesText = text
                        }
                        self.logManual(text: text)
                        self.beginReview(element: element)
                    }
                }
            } else {
                logManual(text: text)
                beginReview(element: element)   // step through each word with a popover
            }
            return
        }

        let issues = mergedIssues(in: text)

        // --- Live typing path: autocorrect the obvious, otherwise just update the count badge.
        // NO suggestion popovers while typing — the user reviews on demand with ⌃⌘C.
        if settings.autocorrectEnabled,
           let issue = issues.first(where: {
               $0.disposition == .autocorrect && isWordComplete($0.range, in: text)
           }),
           let correction = AutocorrectPolicy.autocorrection(for: issue.word) {
            applyAutocorrect(issue: issue, correction: correction, element: element, text: text)
            return   // the resulting edit re-triggers process(), which refreshes the badge
        }
        onIssueCount?(settings.suggestionsEnabled ? issues.count : 0)
    }

    private func logManual(text: String) {
        let issues = mergedIssues(in: text)
        let words = issues.map { "\($0.word)→\($0.topGuess ?? "?")" }.joined(separator: ", ")
        Log.write("[check] read \(text.count) chars; \(issues.count) issue(s)"
                + (issues.isEmpty ? "" : ": \(words)"))
    }

    // MARK: Review session (⌃⌘C steps through each flagged word)

    private func beginReview(element: AXUIElement) {
        reviewing = true
        showNextReviewIssue()
    }

    /// Show the leftmost outstanding issue. Re-reads the composer each step so ranges stay correct
    /// after an edit, and highlights the word (selecting it also anchors the popover near it).
    private func showNextReviewIssue() {
        guard reviewing, let element = monitor.lastSlackElement,
              let text = AX.string(element, kAXValueAttribute as String), !text.isEmpty else {
            endReview(); return
        }
        let issues = mergedIssues(in: text)
            .filter { !reviewSkipped.contains($0.word.lowercased()) }
        guard let issue = issues.first else {
            Log.write("[review] done — no more issues\(reviewSkipped.isEmpty ? "" : " (\(reviewSkipped.count) skipped)")")
            endReview(); return
        }
        Log.write("[review] \(issues.count) left; showing \"\(issue.word)\" → \(Array(issue.guesses.prefix(3)))")
        // Select/highlight the word — shows the user which word, and gives usable caret bounds.
        _ = AX.setSelectedRange(element, location: issue.range.location, length: issue.range.length)
        let cursor = AX.range(element, kAXSelectedTextRangeAttribute as String)
        onSuggestion?(issue, wordBounds(issue.range, element: element, cursor: cursor))
    }

    /// Skip the current word for the rest of this review — advance without applying or ignoring, so
    /// the word stays flagged (still counted, and reviewable again next time).
    func skipCurrentReview(_ issue: SpellIssue) {
        reviewSkipped.insert(issue.word.lowercased())
        Log.write("[review] skipped \"\(issue.word)\"")
        if reviewing { showNextReviewIssue() } else { onDismissUI?() }
    }

    func endReview() {
        guard reviewing else { onDismissUI?(); return }
        reviewing = false
        reviewSkipped.removeAll()
        onDismissUI?()
        // Refresh the badge with whatever remains.
        if let element = monitor.lastSlackElement,
           let text = AX.string(element, kAXValueAttribute as String) {
            onIssueCount?(mergedIssues(in: text).count)
        }
    }

    // MARK: Bulk AI auto-correct

    /// Run an AI spell check on the whole message and apply the top suggestion for every flagged word
    /// (AI + dictionary) in a single write, as one undoable change. Triggered from the menu.
    func autocorrectSentenceWithAI() {
        _ = monitor.acquireSlackComposer()
        guard let element = monitor.lastSlackElement,
              let text = AX.string(element, kAXValueAttribute as String), !text.isEmpty else {
            Log.write("[aispell] auto-correct: no composer text"); onDismissUI?(); return
        }
        Task { [weak self] in
            guard let self else { return }
            let ai = (self.settings.aiSpellEnabled && !self.settings.aiSpellModel.isEmpty)
                ? await self.aiChecker.check(text, modelId: self.settings.aiSpellModel) : []
            await MainActor.run { self.applyAllCorrections(ai: ai, element: element, text: text) }
        }
    }

    private func applyAllCorrections(ai aiIssues: [SpellIssue], element: AXUIElement, text: String) {
        // AI issues first; add dictionary suggestions that don't overlap them.
        var all = aiIssues
        for d in spell.issues(in: text) where !all.contains(where: {
            NSIntersectionRange($0.range, d.range).length > 0
        }) { all.append(d) }
        all = all.filter { !ignored.contains($0.word.lowercased()) && $0.topGuess != nil }
                 .sorted { $0.range.location > $1.range.location }   // back-to-front keeps ranges valid
        guard !all.isEmpty else { Log.write("[aispell] auto-correct: nothing to fix"); onDismissUI?(); return }

        var working = text as NSString
        var applied = 0
        for issue in all {
            guard issue.range.location + issue.range.length <= working.length,
                  working.substring(with: issue.range) == issue.word,
                  let rep = issue.topGuess else { continue }
            working = working.replacingCharacters(in: issue.range, with: rep) as NSString
            applied += 1
        }
        guard applied > 0 else { onDismissUI?(); return }

        suppress()
        guard AX.setValue(element, working as String) == .success else {
            Log.write("[aispell] auto-correct: setValue rejected"); return
        }
        Log.write("[aispell] auto-corrected \(applied) word(s) in one pass")
        // A single whole-message undo record so the user can revert the batch from the chip.
        let record = Correction(
            original: text, corrected: working as String,
            rangeAfter: NSRange(location: 0, length: working.length),
            contextBefore: "", contextAfter: "")
        corrections.append(record)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let bounds = self.wordBounds(NSRange(location: 0, length: 1), element: element,
                                         cursor: AX.range(element, kAXSelectedTextRangeAttribute as String))
            self.onAutocorrect?(record, bounds)
        }
    }

    /// A word is "complete" (safe to autocorrect) when a boundary character follows it — i.e. the
    /// user has moved on. A word at the very end of the text is still being typed, so we wait.
    private func isWordComplete(_ range: NSRange, in text: String) -> Bool {
        let ns = text as NSString
        let end = range.location + range.length
        guard end < ns.length else { return false }
        let next = ns.substring(with: NSRange(location: end, length: 1))
        let boundary = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return next.rangeOfCharacter(from: boundary) != nil
    }

    private func nearest(_ issues: [SpellIssue], toCursor cursor: CFRange?) -> SpellIssue? {
        guard let cursor else { return issues.first }
        return issues.min { a, b in
            abs(a.range.location - cursor.location) < abs(b.range.location - cursor.location)
        }
    }

    // MARK: Apply / undo

    private func applyAutocorrect(issue: SpellIssue, correction: String,
                                  element: AXUIElement, text: String) {
        let ns = text as NSString
        // The word must still be exactly where we found it (user may have typed on).
        guard issue.range.location + issue.range.length <= ns.length,
              ns.substring(with: issue.range) == issue.word else { return }

        guard replace(range: issue.range, with: correction, in: element, currentText: text) else { return }

        let rangeAfter = NSRange(location: issue.range.location, length: (correction as NSString).length)
        let correctionRecord = Correction(
            original: issue.word, corrected: correction, rangeAfter: rangeAfter,
            contextBefore: context(before: issue.range, in: ns),
            contextAfter: context(after: issue.range, in: ns))
        corrections.append(correctionRecord)
        Log.write("autocorrect: \"\(issue.word)\" → \"\(correction)\" at \(issue.range.location)")

        // Bounds computed after a short settle so AXBoundsForRange reflects the new text.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let bounds = self.wordBounds(rangeAfter, element: element,
                                         cursor: AX.range(element, kAXSelectedTextRangeAttribute as String))
            self.onAutocorrect?(correctionRecord, bounds)
        }
    }

    /// Apply a suggestion the user picked from the popover. Like autocorrect, but user-initiated
    /// and for any disposition — still records an undoable correction and shows the chip.
    func applySuggestion(_ issue: SpellIssue, replacement: String) {
        guard let element = monitor.lastSlackElement,
              let text = AX.string(element, kAXValueAttribute as String) else { return }
        let ns = text as NSString
        guard issue.range.location + issue.range.length <= ns.length,
              ns.substring(with: issue.range) == issue.word else {
            Log.write("apply suggestion skipped: \"\(issue.word)\" no longer at expected range")
            return
        }

        guard replace(range: issue.range, with: replacement, in: element, currentText: text) else { return }

        let rangeAfter = NSRange(location: issue.range.location, length: (replacement as NSString).length)
        let record = Correction(
            original: issue.word, corrected: replacement, rangeAfter: rangeAfter,
            contextBefore: context(before: issue.range, in: ns),
            contextAfter: context(after: issue.range, in: ns))
        corrections.append(record)
        Log.write("apply suggestion: \"\(issue.word)\" → \"\(replacement)\"")

        if reviewing {
            // In a review, move straight to the next word once the write settles — no undo chip
            // (it would clutter the step-through). The whole message stays undoable elsewhere.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showNextReviewIssue()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let bounds = self.wordBounds(rangeAfter, element: element,
                                         cursor: AX.range(element, kAXSelectedTextRangeAttribute as String))
            self.onAutocorrect?(record, bounds)
        }
    }

    func undo(_ correction: Correction) {
        guard let element = monitor.lastSlackElement,
              let text = AX.string(element, kAXValueAttribute as String) else { return }
        let ns = text as NSString
        // Never corrupt: only reverse if the corrected word is still exactly where we left it.
        guard correction.rangeAfter.location + correction.rangeAfter.length <= ns.length,
              ns.substring(with: correction.rangeAfter) == correction.corrected else {
            Log.write("undo skipped: surrounding text drifted for \"\(correction.corrected)\"")
            corrections.removeAll { $0.id == correction.id }
            return
        }
        _ = replace(range: correction.rangeAfter, with: correction.original,
                    in: element, currentText: text)
        ignored.insert(correction.original.lowercased())   // don't immediately re-correct it
        corrections.removeAll { $0.id == correction.id }
        Log.write("undo: \"\(correction.corrected)\" → \"\(correction.original)\" (now ignored)")
    }

    /// Replace a character range using the PROVEN whole-text `setValue` path (Phase 1 showed
    /// Slack's Quill composer applies `setValue` reliably but ignores targeted `setSelectedText`).
    /// Restores the caret just after the replacement, once the async write settles.
    @discardableResult
    private func replace(range: NSRange, with replacement: String,
                         in element: AXUIElement, currentText: String) -> Bool {
        let ns = currentText as NSString
        guard range.location + range.length <= ns.length else { return false }
        let newText = ns.replacingCharacters(in: range, with: replacement)
        suppress()
        guard AX.setValue(element, newText) == .success else {
            Log.write("replace failed: setValue rejected")
            return false
        }
        let caret = range.location + (replacement as NSString).length
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            _ = AX.setSelectedRange(element, location: caret, length: 0)
        }
        return true
    }

    /// User chose "Ignore this word" — stop flagging it this session. Advances the review.
    func ignore(_ issue: SpellIssue) {
        ignored.insert(issue.word.lowercased())
        Log.write("[review] ignoring \"\(issue.word)\"")
        if reviewing { showNextReviewIssue() } else { onDismissUI?() }
    }

    /// Test-only: exercise the exact click-to-apply path a user takes from the suggestion popover.
    /// Returns the applied (issue, replacement) so a driver can verify the result.
    @discardableResult
    func applyFirstSuggestionForTest() -> (word: String, replacement: String)? {
        guard let element = monitor.lastSlackElement,
              let text = AX.string(element, kAXValueAttribute as String) else { return nil }
        let issues = spell.issues(in: text).filter { !ignored.contains($0.word.lowercased()) }
        guard let issue = issues.first(where: { $0.disposition == .suggest }),
              let guess = issue.topGuess else {
            Log.write("test: no suggestion available to apply"); return nil
        }
        applySuggestion(issue, replacement: guess)
        return (issue.word, guess)
    }

    // MARK: Geometry

    private func wordBounds(_ range: NSRange, element: AXUIElement, cursor: CFRange?) -> CGRect? {
        let composerAX = AX.frame(element)

        // 1. The word's own bounds — ideal ("near the word"), when Slack reports them usably.
        if let w = AX.boundsForRange(element, location: range.location, length: max(range.length, 1)),
           isSane(w, within: composerAX) {
            Log.write("popover: anchoring to word bounds \(rectStr(w))")
            return Geometry.cocoaRect(fromAX: w)
        }
        // 2. The caret/insertion bounds — still "near the cursor", which is what the user is watching.
        //    Slack's Quill editor often returns zero-size word rects but a usable caret rect.
        if let cursor,
           let c = AX.boundsForRange(element, location: cursor.location, length: max(cursor.length, 1)),
           isSane(c, within: composerAX, allowZeroWidth: true) {
            Log.write("popover: anchoring to caret bounds \(rectStr(c))")
            // Give a zero-width caret a little height so the popover sits just under the line.
            let rect = CGRect(x: c.origin.x, y: c.origin.y,
                              width: max(c.width, 1), height: max(c.height, 16))
            return Geometry.cocoaRect(fromAX: rect)
        }
        // 3. Last resort: the composer frame (design-sanctioned fallback when bounds are unavailable).
        if let f = composerAX {
            Log.write("popover: anchoring to composer frame \(rectStr(f))")
            return Geometry.cocoaRect(fromAX: f)
        }
        return nil
    }

    /// A bounds rect is usable if it has real height and its position falls near the composer (so we
    /// reject window-relative or off-screen garbage). Word rects need width; caret rects may be zero-wide.
    private func isSane(_ r: CGRect, within composer: CGRect?, allowZeroWidth: Bool = false) -> Bool {
        guard r.height > 0, allowZeroWidth || r.width > 0 else { return false }
        guard let c = composer else { return true }
        return c.insetBy(dx: -8, dy: -80).contains(CGPoint(x: r.midX, y: r.midY))
    }

    private func rectStr(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.width, r.height)
    }

    private func context(before range: NSRange, in ns: NSString, span: Int = 12) -> String {
        let start = max(0, range.location - span)
        return ns.substring(with: NSRange(location: start, length: range.location - start))
    }

    private func context(after range: NSRange, in ns: NSString, span: Int = 12) -> String {
        let end = range.location + range.length
        let length = min(span, ns.length - end)
        guard length > 0 else { return "" }
        return ns.substring(with: NSRange(location: end, length: length))
    }
}
