import Foundation
import SignalCore

@MainActor extension SignalSession {
    func mediaIsAvailable(path: String, messageId: String? = nil) -> Bool {
        guard let db = clientDatabase else { return false }
        return (try? db.pool.read { try MediaAvailability.permits($0, path: path, messageId: messageId) }) == true
    }

    func observeMediaAvailability() {
        mediaObservationGeneration &+= 1
        let generation = mediaObservationGeneration
        mediaAvailabilityTask?.cancel()
        mediaExpiryTask?.cancel()
        applyMediaAvailability(MediaAvailability())
        guard let db = clientDatabase else { return }
        mediaAvailabilityTask = Task { [weak self] in
            do {
                for try await state in db.mediaAvailabilityUpdates() {
                    guard let self, !Task.isCancelled, generation == mediaObservationGeneration else { return }
                    applyMediaAvailability(state)
                    scheduleMediaExpiry(state, database: db, generation: generation)
                }
            } catch {
                guard let self, !Task.isCancelled, generation == mediaObservationGeneration else { return }
                applyMediaAvailability(MediaAvailability())
            }
        }
    }

    func scheduleMediaExpiry(_ state: MediaAvailability, database: SignalDatabase, generation: UInt64) {
        mediaExpiryTask?.cancel()
        guard let expiration = state.nextExpiration else { return }
        mediaExpiryTask = Task { [weak self] in
            do {
                let delay = max(1, expiration - Int64(Date().timeIntervalSince1970 * 1000))
                try await Task.sleep(for: .milliseconds(delay))
                let next = try await database.mediaAvailability()
                guard let self, !Task.isCancelled, generation == mediaObservationGeneration else { return }
                applyMediaAvailability(next)
                scheduleMediaExpiry(next, database: database, generation: generation)
            } catch {
                guard let self, !Task.isCancelled, generation == mediaObservationGeneration else { return }
                applyMediaAvailability(MediaAvailability())
            }
        }
    }

    /// Called on deletion, erasure, expiration and session replacement.
    func applyMediaAvailability(_ state: MediaAvailability) {
        for path in audioWaveforms.keys where !state.paths.contains(path) { audioWaveforms.removeValue(forKey: path) }
        for (key, path) in imagePaths where !state.paths.contains(path) {
            forgetImage(key)
            imagePaths[key] = nil
        }
        if let box = lightbox, !state.messageIds.contains(box.messageId) || box.attachments.contains(where: { a in
            a.path.map { state.messagePaths[box.messageId]?.contains($0) != true } ?? false
        }) { closeLightbox() }
        if let video = inlineVideo, state.messagePaths[video.messageId]?.contains(video.path) != true { stopInlineVideo() }
        if let id = activeAudioMessageId, activeAudioPath.map({ state.messagePaths[id]?.contains($0) == true }) != true { stopAudio() }
    }
}
