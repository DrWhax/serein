// Shared by the probe service and host (Tools/check-sandbox-profile.sh).
import Foundation

@objc protocol ProbeProtocol {
    func run(reply: @escaping (String) -> Void)
}
