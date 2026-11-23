import Synchronization

/// Per-participant frame sinks for the endpoint's synchronous XPC frame callbacks.
package final class GroupCallVideo: Sendable {
    let local = DirectCallVideo()
    private let sinks = Mutex([UInt32: DirectCallVideo]())

    package func submit(width: Int, height: Int, format: Int, data: [UInt8]) -> Bool {
        local.submit(width: width, height: height, format: format, data: data)
    }
    package func receive(demuxID: UInt32, maxWidth: Int, maxHeight: Int, into buffer: inout [UInt8]) -> (width: Int, height: Int)? {
        sinks.withLock { $0[demuxID] }?.receive(maxWidth: maxWidth, maxHeight: maxHeight, into: &buffer)
    }
    func install(_ id: UInt32, _ sink: DirectCallVideo) { sinks.withLock { $0[id] = sink } }
    func remove(_ id: UInt32) { sinks.withLock { $0.removeValue(forKey: id) }?.close() }
    func close() {
        local.close()
        sinks.withLock { peers in for sink in peers.values { sink.close() }; peers.removeAll() }
    }
}
