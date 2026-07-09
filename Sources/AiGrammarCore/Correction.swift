import Foundation

/// A recorded correction, enough to reverse it safely. Undo only proceeds if the surrounding text
/// still matches (verified against `contextBefore`/`contextAfter`), per the design doc's
/// "never corrupt the message" rule.
public struct Correction: Identifiable, Equatable {
    public let id: UUID
    public let original: String
    public let corrected: String
    /// Range of `corrected` in the text immediately after applying.
    public let rangeAfter: NSRange
    /// A few characters on each side of the correction, to detect drift before undoing.
    public let contextBefore: String
    public let contextAfter: String
    public let timestamp: Date

    public init(id: UUID = UUID(), original: String, corrected: String,
                rangeAfter: NSRange, contextBefore: String, contextAfter: String,
                timestamp: Date = Date()) {
        self.id = id
        self.original = original
        self.corrected = corrected
        self.rangeAfter = rangeAfter
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.timestamp = timestamp
    }
}
