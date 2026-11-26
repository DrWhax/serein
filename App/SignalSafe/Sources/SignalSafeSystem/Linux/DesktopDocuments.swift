#if os(Linux)
import CLinuxDesktop
import Foundation

public enum DesktopDocuments {
    public static func readDrop(_ url: URL, limit: Int) -> Data? {
        guard url.isFileURL, limit >= 0, limit < Int.max else { return nil }
        let fd = serein_open_dropped_document(Array(url.path.utf8).span, Int64(limit))
        guard fd >= 0 else { return nil }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? input.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }
}
#endif
