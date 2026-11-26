#if os(Linux)
import CLinuxCallAudio
import Foundation

extension VoiceAudioRoutes {
    package static func read(input: Bool) throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            var destination = bytes.mutableSpan
            let size = Int(serein_call_pcm_routes(input ? 1 : 0, &destination))
            guard size >= 0 else { throw CallMicrophone.Failure.unavailable }
            if size > bytes.count {
                bytes = [UInt8](repeating: 0, count: size)
                continue
            }
            let fields = bytes.prefix(size).split(separator: 0)
            var devices = [VoiceAudioRoute]()
            for index in stride(from: 0, to: fields.count - 1, by: 2) {
                let uid = String(decoding: fields[index], as: UTF8.self)
                let label = String(decoding: fields[index + 1], as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
                devices.append(.init(uid: uid, name: label))
            }
            return Self(devices: devices, currentDefault: devices.first { $0.uid == "default" })
        }
    }
}

package final class VoiceAudioMonitor: Sendable {
    private let observer: Task<Void, Never>
    package init(changed: @escaping @Sendable () -> Void) throws {
        let inputs = try VoiceAudioRoutes.read(input: true)
        let outputs = try VoiceAudioRoutes.read(input: false)
        observer = Task.detached(priority: .utility) {
            var last = (inputs, outputs)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let inputs = try? VoiceAudioRoutes.read(input: true),
                      let outputs = try? VoiceAudioRoutes.read(input: false) else { continue }
                if last != (inputs, outputs) { last = (inputs, outputs); changed() }
            }
        }
    }
    deinit { observer.cancel() }
}
#endif
