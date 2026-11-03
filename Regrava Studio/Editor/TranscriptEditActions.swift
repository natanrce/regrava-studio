@preconcurrency import AVFoundation
import AppKit
import RegravaCore

// Edit-by-transcript actions.

extension EditorModel {
    /// Word and pause tokens of the transcript, in source time.
    var transcriptTokens: [TranscriptToken] {
        if let transcriptTokensCache { return transcriptTokensCache }
        guard let transcript else { return [] }
        let tokens = TranscriptEditing.tokens(transcript.transcript, locale: transcript.generator.locale)
        transcriptTokensCache = tokens
        return tokens
    }

    /// Whether any of the token is still in the video (`TranscriptEditing.isPresent`).
    func isPresent(_ token: TranscriptToken) -> Bool {
        resolver.isSourceRangePresent(token.sourceStartMs, token.sourceEndMs)
    }

    /// Keeps the playhead on the same recording moment across cuts (`stickyAction`).
    private func keepingPlayhead(_ body: () -> Void) {
        let source = currentSourceTimeMs
        body()
        if project.resolver.isSourceTimePresent(source) { seek(to: project.resolver.sourceToPlayback(source)) }
    }

    /// `deleteTokens` / `cutTargetFromVideo`.
    @discardableResult
    func cutFromVideo(_ target: [TranscriptToken]) -> Bool {
        var updated = project
        switch TranscriptEditing.delete(target, tokens: transcriptTokens, project: &updated) {
        case .nothing:
            return false
        case .wouldRemoveAll:
            showToast("Can't delete the entire video", durationMs: 2000)
            return false
        case .removed(let ms):
            keepingPlayhead { change { $0 = updated } }
            showToast(String(format: "Removed %.1fs — ⌘Z to undo", ms / 1000), durationMs: 2500)
            return true
        }
    }

    /// `cutTargetFromTranscript`: hidden from captions, the video plays them.
    func cutFromTranscript(_ target: [TranscriptToken]) {
        guard let words = transcript?.transcript else { return }
        let picked = target.filter { $0.kind == .word && !$0.isHidden && isPresent($0) }
        guard let first = picked.compactMap(\.wordIndex).min(), let last = picked.compactMap(\.wordIndex).max() else { return }
        changeTranscript(TranscriptEditing.setHidden(words, from: first, to: last, hidden: true))
        let n = picked.count
        showToast("Cut \(n) word\(n == 1 ? "" : "s") from the transcript — the video is unchanged, Restore brings \(n == 1 ? "it" : "them") back", durationMs: 2500)
    }

    /// `restoreTarget`: back into the video and the captions.
    func restore(_ target: [TranscriptToken]) {
        guard var words = transcript?.transcript else { return }
        var updated = project
        TranscriptEditing.restore(target, project: &updated)
        let hidden = target.filter { $0.kind == .word && $0.isHidden }.compactMap(\.wordIndex)
        if let first = hidden.min(), let last = hidden.max() {
            words = TranscriptEditing.setHidden(words, from: first, to: last, hidden: false)
        }
        keepingPlayhead { changeTranscript(words) { $0 = updated } }
    }

    /// Typed corrections of words `i0…i1`.
    func correctTranscript(from i0: Int, to i1: Int, text: String) {
        guard let words = transcript?.transcript, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        changeTranscript(TranscriptEditing.correct(words, from: i0, to: i1, text: text))
    }

    var presentFillerTokens: [TranscriptToken] {
        transcriptTokens.filter { $0.kind == .word && $0.fillerTier == 1 && isPresent($0) }
    }

    var tightenablePauseTokens: [TranscriptToken] {
        transcriptTokens.filter { $0.kind == .gap && isPresent($0) && TranscriptEditing.canTighten($0, in: project) }
    }

    /// "Play": this part once, then back to its start (40 ms minimum).
    func audition(_ target: [TranscriptToken]) {
        guard let first = target.first, let last = target.last else { return }
        let resolver = project.resolver
        let start = resolver.sourceToPlayback(first.sourceStartMs + 1)
        let end = resolver.sourceToPlayback(last.sourceEndMs)
        guard end - start >= 40 else { return }
        seek(to: start)
        if !isPlaying { togglePlay() }
        let item = player.currentItem
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((end - start) / max(self?.playbackRate ?? 1, 0.1) * 1_000_000))
            guard let self, self.isPlaying, self.player.currentItem === item else { return }
            self.pause()
            self.seek(to: start)
        }
    }
}
