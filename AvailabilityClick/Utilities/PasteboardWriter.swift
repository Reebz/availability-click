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
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        let formatter = AvailabilityFormatter()
        let plain = formatter.format(
            slots: slots,
            showTimeZone: showTimeZone,
            template: template,
            timezone: timezone
        )
        guard !plain.isEmpty else { return false }

        pasteboard.clearContents()

        if template == .plainText {
            let attributed = formatter.formatAttributed(
                slots: slots,
                showTimeZone: showTimeZone,
                timezone: timezone
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
}
