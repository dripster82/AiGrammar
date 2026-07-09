import AppKit
import ApplicationServices

/// Thin wrappers over the C Accessibility API. All calls are synchronous and cheap; errors are
/// collapsed to nil because Phase 1 only cares about "does Slack expose this or not".
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "grant Accessibility" prompt (once); the user completes the grant in
    /// System Settings > Privacy & Security > Accessibility.
    static func promptForTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    /// Chromium/Electron apps (Slack) keep their accessibility tree OFF until an assistive client
    /// asks for it. Setting AXManualAccessibility on the app element forces the web content —
    /// including the message composer — to be exposed. Without this, reads return an empty tree
    /// even when Accessibility permission is granted.
    @discardableResult
    static func enableManualAccessibility(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        let err = AXUIElementSetAttributeValue(
            appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return err == .success
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func systemWideFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    static func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return range
    }

    static func int(_ element: AXUIElement, _ attribute: String) -> Int? {
        (copyAttribute(element, attribute) as? NSNumber)?.intValue
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttribute(element, kAXChildrenAttribute as String),
              CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    /// Parameterized AXStringForRange — an alternative text read that can work when AXValue does not.
    static func stringForRange(_ element: AXUIElement, location: Int, length: Int) -> String? {
        var range = CFRange(location: location, length: length)
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXStringForRange" as CFString, param, &value) == .success else { return nil }
        return value as? String
    }

    /// Depth-first concatenation of descendant text (AXStaticText/AXTextArea values). Fallback read
    /// for editors that split content across child nodes instead of exposing a single AXValue.
    static func descendantText(_ element: AXUIElement, depth: Int = 0) -> String {
        guard depth < 8 else { return "" }
        var parts: [String] = []
        if let role = string(element, kAXRoleAttribute as String),
           role == kAXStaticTextRole as String || role == kAXTextAreaRole as String,
           let v = string(element, kAXValueAttribute as String), !v.isEmpty {
            parts.append(v)
        }
        for child in children(element) {
            let sub = descendantText(child, depth: depth + 1)
            if !sub.isEmpty { parts.append(sub) }
        }
        return parts.joined(separator: " ")
    }

    static func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    static func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// Screen bounds of a character range — the attribute underline overlays (V2) depend on.
    static func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, "AXBoundsForRange" as CFString, param, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue((value as! AXValue), .cgRect, &rect) else { return nil }
        return rect
    }

    /// Screen frame of an element (position + size), for fallback popover placement.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let posVal = copyAttribute(element, kAXPositionAttribute as String),
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              let sizeVal = copyAttribute(element, kAXSizeAttribute as String),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue((posVal as! AXValue), .cgPoint, &pos),
              AXValueGetValue((sizeVal as! AXValue), .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    @discardableResult
    static func setValue(_ element: AXUIElement, _ text: String) -> AXError {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
    }

    @discardableResult
    static func setSelectedRange(_ element: AXUIElement, location: Int, length: Int) -> AXError {
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    /// Replace only the current selection (works on some Electron fields where setting the whole
    /// AXValue does not).
    @discardableResult
    static func setSelectedText(_ element: AXUIElement, _ text: String) -> AXError {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
    }
}
