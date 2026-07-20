import ApplicationServices

/// Shared write path for corrections and rewrites. Prefers a TARGETED select-and-replace
/// (`setSelectedText`) so rich-text formatting — headers, lists, bold — survives, since whole-text
/// `setValue` flattens a formatted document. Verifies the targeted write actually applied (Slack's
/// Quill reports it settable but silently ignores it), and only then falls back to whole-text
/// `setValue` for plain fields that need it.
enum AXWrite {
    /// Replace `range` with `replacement` in `element`, leaving the caret at `caret` (a location in the
    /// resulting text). Returns false only if no write path worked.
    @discardableResult
    static func replace(_ element: AXUIElement, range: NSRange, with replacement: String,
                        currentText: String, caret: Int) -> Bool {
        let expectedDelta = (replacement as NSString).length - range.length

        // --- 1. Targeted select-and-replace (preserves formatting) ---
        if AX.isSettable(element, kAXSelectedTextAttribute as String) {
            let nBefore = AX.int(element, kAXNumberOfCharactersAttribute as String)
            _ = AX.setSelectedRange(element, location: range.location, length: range.length)
            let selBefore = AX.string(element, kAXSelectedTextAttribute as String)
            if AX.setSelectedText(element, replacement) == .success {
                let nAfter = AX.int(element, kAXNumberOfCharactersAttribute as String)
                let selAfter = AX.string(element, kAXSelectedTextAttribute as String)
                // Did it really change? Slack leaves the length and selection untouched.
                let applied: Bool
                if let a = nAfter, let b = nBefore, expectedDelta != 0 {
                    applied = (a - b == expectedDelta)          // length moved by exactly the delta
                } else if let sb = selBefore, let sa = selAfter {
                    applied = (sa != sb)                         // selection collapsed after insert
                } else {
                    applied = false                             // can't verify → don't trust it
                }
                if applied {
                    _ = AX.setSelectedRange(element, location: caret, length: 0)
                    return true
                }
            }
        }

        // --- 2. Whole-text setValue (plain fields: Slack, most web textareas) ---
        let ns = currentText as NSString
        guard range.location + range.length <= ns.length,
              AX.isSettable(element, kAXValueAttribute as String) else {
            Log.write("write: no usable path (targeted ignored, setValue unavailable)")
            return false
        }
        let newText = ns.replacingCharacters(in: range, with: replacement)
        guard AX.setValue(element, newText) == .success else {
            Log.write("write: setValue rejected")
            return false
        }
        // Quill applies setValue asynchronously — restore the caret after it settles, unless the user
        // has typed since (don't fight a cursor they've moved).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if AX.string(element, kAXValueAttribute as String) == newText {
                _ = AX.setSelectedRange(element, location: caret, length: 0)
            }
        }
        return true
    }
}
