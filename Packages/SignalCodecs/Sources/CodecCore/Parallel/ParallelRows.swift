// Row-parallel construction of a flat buffer: each chunk of rows is filled into an array of
// its own on a worker, and the chunks are concatenated in order. For per-row work whose
// rows depend only on read-only inputs (colour conversion, upsampling, transforms of
// independent block rows).

public import Dispatch
public import Synchronization

public enum ParallelRows {
    /// `rows` rows of `rowLength` elements: `fill(range, &chunk)` writes rows `range` into
    /// `chunk` (range.count · rowLength elements, initially `zero`). Chunks are about
    /// `chunk` rows; a single chunk runs on the calling thread. `fill` runs on several threads
    /// at once.
    @inlinable
    public static func build<T: Sendable>(rows: Int, rowLength: Int, chunk: Int, zero: T,
                                          _ fill: @Sendable (Range<Int>, inout [T]) -> Void) -> [T] {
        guard rows > 0, rowLength > 0 else { return [] }
        let size = max(1, chunk)
        let chunks = (rows + size - 1) / size
        if chunks == 1 {
            var out = [T](repeating: zero, count: rows * rowLength)
            fill(0..<rows, &out)
            return out
        }
        let results = Mutex<[[T]]>(Array(repeating: [], count: chunks))
        DispatchQueue.concurrentPerform(iterations: chunks) { k in
            let lo = k * size, hi = min(rows, lo + size)
            var part = [T](repeating: zero, count: (hi - lo) * rowLength)
            fill(lo..<hi, &part)
            let done = part
            results.withLock { $0[k] = done }
        }
        var out: [T] = []
        out.reserveCapacity(rows * rowLength)
        for part in results.withLock({ $0 }) { out += part }
        return out
    }
}
