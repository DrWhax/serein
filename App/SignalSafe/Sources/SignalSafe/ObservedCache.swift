// Caches the timeline reads while drawing (decoded images, sticker pixels, GIF players),
// observed per key: a row that read one entry re-renders when that entry changes, not when any
// other image finishes decoding (a shared @Observable dictionary invalidated every row that had
// looked anything up, on every decode — the cause of scroll hitches).

import Observation

@MainActor @Observable final class CacheSlot<Value> {
    var value: Value?
    init() {}
}

@MainActor final class ObservedCache<Value> {
    private var slots: [String: CacheSlot<Value>] = [:]

    subscript(key: String) -> Value? {
        get { slot(key).value }
        set { slot(key).value = newValue }
    }

    private func slot(_ key: String) -> CacheSlot<Value> {
        if let s = slots[key] { return s }
        let s = CacheSlot<Value>()
        slots[key] = s
        return s
    }

    /// Removes an entry (its readers see nil) and returns what it held.
    @discardableResult func removeValue(forKey key: String) -> Value? {
        let old = slots[key]?.value
        slots[key]?.value = nil
        return old
    }

    var values: [Value] { slots.values.compactMap(\.value) }
    var keys: [String] { slots.compactMap { key, slot in slot.value.map { _ in key } } }

    func removeAll() {
        for s in slots.values { s.value = nil }
    }
}
