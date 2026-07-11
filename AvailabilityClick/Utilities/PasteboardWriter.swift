import AppKit

/// Pasteboard I/O for availability output (KTD4). Rich targets read
/// different flavors -- browser-hosted editors (Google Docs, Notion, Slack
/// web) take public.html while native rich editors (Mail, TextEdit) take
/// public.rtf -- so the plain-text template writes .string + .rtf + .html.
/// The markdown template's syntax IS the artifact: .string only.
@MainActor
enum PasteboardWriter {
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

        pasteboard.setString(plain, forType: .string)
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
        let fullRange = NSRange(location: 0, length: attributed.length)
        if let rtf = try? attributed.data(
            from: fullRange, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        if let html = try? attributed.data(
            from: fullRange, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        ) {
            pasteboard.setData(html, forType: .html)
        }

        pasteboard.setString(text, forType: .string)
        return true
    }
}
