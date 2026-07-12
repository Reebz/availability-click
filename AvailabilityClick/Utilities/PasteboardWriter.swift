import AppKit

/// Pasteboard I/O for availability output (KTD4). Rich targets read
/// different flavors -- browser-hosted editors (Google Docs, Notion, Slack
/// web) take public.html while native rich editors (Mail, TextEdit) take
/// public.rtf -- so the plain-text template writes .string + .rtf + .html.
/// The markdown template's syntax IS the artifact: .string only.
@MainActor
enum PasteboardWriter {
    /// `changeCount` captured immediately after our last successful write (R6,
    /// KTD10). Pasting never bumps `changeCount`; any other writer does. nil
    /// until the first write. Every write path below refreshes it, so the
    /// overwrite guard sees the app's own newest write on any path.
    private(set) static var lastWriteChangeCount: Int?

    /// True when the pasteboard still holds our last write untouched — its
    /// `changeCount` equals the snapshot from that write. False before any
    /// write and after another app writes.
    static func pasteboardHoldsOurLastWrite(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard let snapshot = lastWriteChangeCount else { return false }
        return pasteboard.changeCount == snapshot
    }

    /// Writes all flavors after one clearContents(). Returns false (and
    /// leaves the pasteboard untouched) when there is nothing to write.
    @discardableResult
    static func write(
        slots: [Date: [TimeSlot]],
        showTimeZone: Bool,
        timezone: TimeZone? = nil,
        template: FormatTemplate,
        locale: Locale = .autoupdatingCurrent,
        asOf: Date? = nil,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        let formatter = AvailabilityFormatter(locale: locale)
        let plain = formatter.format(
            slots: slots,
            showTimeZone: showTimeZone,
            template: template,
            timezone: timezone,
            asOf: asOf
        )
        guard !plain.isEmpty else { return false }

        pasteboard.clearContents()

        if template == .plainText {
            let attributed = formatter.formatAttributed(
                slots: slots,
                showTimeZone: showTimeZone,
                timezone: timezone,
                asOf: asOf
            )
            writeRichFlavors(attributed, to: pasteboard)
        }

        pasteboard.setString(plain, forType: .string)
        lastWriteChangeCount = pasteboard.changeCount
        return true
    }

    /// Writes pre-rendered text (the U4 proposal sentence) with the same flavor
    /// set as the plain template — .string plus .rtf/.html generated from the
    /// (unformatted) text — so it pastes identically into plain and rich
    /// targets. Returns false and leaves the pasteboard untouched when empty.
    @discardableResult
    static func writeText(_ text: String, pasteboard: NSPasteboard = .general) -> Bool {
        guard !text.isEmpty else { return false }

        pasteboard.clearContents()

        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        )
        writeRichFlavors(attributed, to: pasteboard)

        pasteboard.setString(text, forType: .string)
        lastWriteChangeCount = pasteboard.changeCount
        return true
    }

    /// Writes the .rtf and .html flavors derived from `attributed`. Best-effort:
    /// a flavor whose serialization fails is skipped, never fatal. Callers own
    /// clearContents(), the .string flavor, and the changeCount snapshot.
    private static func writeRichFlavors(_ attributed: NSAttributedString, to pasteboard: NSPasteboard) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        if let rtf = try? attributed.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        if let html = try? attributed.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        ) {
            pasteboard.setData(html, forType: .html)
        }
    }
}
