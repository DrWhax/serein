#if os(Linux)
import CLinuxDesktop
import Foundation
import MediaXPCInterface

public enum AppSandbox {
    public static var realHome: String { NSHomeDirectory() }
    public static func isConfined() -> Bool { serein_desktop_is_confined() != 0 }
    public static func hasServicePeers() -> Bool { XPCPeer.hasAppServiceRoutes }

    @MainActor public static func requireConfinement() {
        guard hasServicePeers(), serein_desktop_confine() != 0 else {
            FileHandle.standardError.write(Data("Serein needs its service channels and Linux desktop sandbox to start.\n".utf8))
            exit(78)
        }
    }
}
#endif
