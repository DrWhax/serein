// The PDF window (app/main `pdf:generate` + ts/components/Pdf + windows/pdf): the account
// keys page (SignalAccountKeys: ACI and backup key, no save button), force-light, laid out
// on a US Letter page (612×792pt, no margins) and printed to PDF. Here the page is drawn at 3x
// and placed on a PDFKit page: a raster page (upstream's printToPDF is vector), since a
// CoreGraphics PDF context can only be created through pointer APIs.

import AppKit
import PDFKit
import SignalI18n
import SwiftUI

public enum AccountKeysPDF {
    public static let pageSize = CGSize(width: 612, height: 792)
    /// `saveAttachmentToDisk` name.
    public static let fileName = "Signal_AccountKeys.pdf"

    /// `generatePDF({ view: 'account-keys', serviceId, backupKey })`
    @MainActor
    public static func generate(serviceId: String?, backupKey: String?, i18n: Localizer) -> Data {
        let page = SignalAccountKeys(serviceId: serviceId, backupKey: backupKey, saveAccountKeysPDF: nil)
            .cssTextColor(.labelPrimary)
            .frame(width: pageSize.width, height: pageSize.height, alignment: .top)
            .background(Color.white)
            .environment(\.i18n, i18n)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: page)
        renderer.proposedSize = ProposedViewSize(pageSize)
        renderer.scale = 3
        guard let image = renderer.cgImage, let pdfPage = PDFPage(image: NSImage(cgImage: image, size: pageSize)) else { return Data() }
        let document = PDFDocument()
        document.insert(pdfPage, at: 0)
        return document.dataRepresentation() ?? Data()
    }
}
