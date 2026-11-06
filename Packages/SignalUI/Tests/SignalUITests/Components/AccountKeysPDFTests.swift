import Foundation
import PDFKit
import Testing
@testable import SignalUI
import SignalI18n

@MainActor
@Suite struct AccountKeysPDFTests {
    @Test func letterSizedPDF() throws {
        let data = AccountKeysPDF.generate(serviceId: "4a6b3f2e-1c2d-4e5f-8a9b-0c1d2e3f4a5b", backupKey: "ABCD1234EFGH5678IJKL9012MNOP3456QRST7890UVWX1234YZAB5678CDEF9012",
                                           i18n: Localizer(locale: "en"))
        #expect(data.starts(with: Array("%PDF".utf8)))
        #expect(PDFDocument(data: data)?.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_ARTIFACTS"] {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("account-keys.pdf"))
        }
    }
}
