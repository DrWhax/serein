#if os(Linux)
import CLinuxDesktop
import Foundation

public enum DesktopPortal {
    private static let requests = DispatchQueue(label: "org.signalsafe.desktop-portal")

    /// Returns true if a supported external link was queued for the desktop.
    public static func open(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["https", "http", "mailto", "tel"].contains(scheme) else { return false }
        requests.async {
            if serein_portal_open(Array(url.absoluteString.utf8).span) == 0 {
                FileHandle.standardError.write(Data("Serein: the desktop portal could not open the link.\n".utf8))
            }
        }
        return true
    }

    public static func revealFile(at path: String) {
        requests.async {
            if serein_portal_reveal(Array(path.utf8).span) == 0 {
                FileHandle.standardError.write(Data("Serein: the desktop portal could not reveal the file.\n".utf8))
            }
        }
    }
}
#endif
