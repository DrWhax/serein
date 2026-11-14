import Foundation

for name in CommandLine.arguments.dropFirst() {
    let channel = XPCChannel(.service(name), peer: nil, timeout: .seconds(10))
    do {
        let ready = try await channel.send(Data([0]), maxReply: 32)
        guard ready == Data("ready".utf8) else { exit(1) }
        do {
            _ = try await channel.send(Data([1]), maxReply: 32)
            print("FAILED: \(name) survived its footprint limit")
            exit(1)
        } catch XPCServiceError.lost {
            print("ok: \(name) measured memory under Seatbelt and terminated on growth")
        }
    } catch {
        print("FAILED: \(name): \(error)")
        exit(1)
    }
}
