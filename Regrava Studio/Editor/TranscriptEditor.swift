import AppKit
import RegravaCore
import SwiftUI

// "Edit by transcript" sidebar section.

struct TranscriptEditPanel: View {
    @ObservedObject var editor: EditorModel
    /// View state `transcript-editor-view-2`.
    @AppStorage("transcript-editor-view-2.showDeletedText") private var showDeletedText = true
    @AppStorage("transcript-editor-view-2.showHiddenText") private var showHiddenText = true

    var body: some View {
        if editor.transcript == nil {
            SidebarSection(title: "Edit by transcript", showsDivider: false) {
                Text("Edit your video by editing its text: delete words to cut them out, remove filler words and long pauses in one click.")
                    .font(Theme.Typo.copy)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Generate a transcript first to get started.")
                    .font(Theme.Typo.label)
                    .foregroundStyle(Theme.Colors.tertiary)
                RSButton(title: "Generate transcript", kind: .primary) { editor.openSidebar(.captions) }
            }
        } else {
            let tokens = editor.transcriptTokens
            let deleted = tokens.contains { !editor.isPresent($0) }
            let hidden = tokens.contains { $0.isHidden }
            SidebarSection(title: "Edit by transcript", showsDivider: false) {
                bulkActions
                TranscriptTextEditor(editor: editor, showDeletedText: showDeletedText, showHiddenText: showHiddenText)
                Text("Type to correct the text — ⌫ cuts words out of the video, ⌘⌫ cuts them from the transcript only.")
                    .font(Theme.Typo.label)
                    .foregroundStyle(Theme.Colors.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if deleted {
                    ToggleRow(title: "Show deleted text", description: "Keep cut words visible as strikethrough so they can be restored.", isOn: $showDeletedText)
                }
                if hidden {
                    ToggleRow(title: "Show hidden words", description: "Keep words hidden from captions visible here so they can be restored.", isOn: $showHiddenText)
                }
                if tokens.contains(where: { $0.wordType == "sound-label" }) {
                    ToggleRow(title: "Show sound labels", description: "Adds sounds such as [keyboard clacking] to your captions.", isOn: editor.binding(\.captions.showSoundLabels))
                }
            }
        }
    }

    /// Shown only when there is something to act on.
    @ViewBuilder
    private var bulkActions: some View {
        let fillers = editor.presentFillerTokens
        let pauses = editor.tightenablePauseTokens
        if !fillers.isEmpty || !pauses.isEmpty {
            WrappingHStack(spacing: Theme.gap(1)) {
                if !fillers.isEmpty {
                    RSButton(title: "Remove \(fillers.count) filler word\(fillers.count == 1 ? "" : "s")", icon: "waveform.badge.minus", kind: .secondary) {
                        editor.cutFromVideo(fillers)
                    }
                    .fixedSize()
                    .tooltip("Cut every detected filled pause (\"um\", \"uh\"...) out of the video")
                }
                if !pauses.isEmpty {
                    RSButton(title: "Tighten \(pauses.count) pause\(pauses.count == 1 ? "" : "s")", icon: "timeline.selection", kind: .secondary) {
                        editor.cutFromVideo(pauses)
                    }
                    .fixedSize()
                    .tooltip("Shorten every long pause, keeping a natural breath on each side")
                }
            }
        }
    }
}

// MARK: - Editable body

struct TranscriptTextEditor: NSViewRepresentable {
    /// Redraws with the playhead (`EditorModel.clock`).
    @EnvironmentObject private var clock: PlaybackClock
    @ObservedObject var editor: EditorModel
    var showDeletedText: Bool
    var showHiddenText: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TranscriptNSTextView {
        let view = TranscriptNSTextView()
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.drawsBackground = false
        // 14 px on the left for the gutter dot, none on the right.
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = true
        view.insertionPointColor = .white
        view.selectedTextAttributes = [.backgroundColor: NSColor(Theme.Colors.primary).withAlphaComponent(0.35)]
        view.setAccessibilityLabel("Transcript")
        context.coordinator.textView = view
        return view
    }

    func updateNSView(_ view: TranscriptNSTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.editor = editor
        let signature = Signature(words: editor.transcript?.transcript ?? [], slices: editor.project.slices, showDeleted: showDeletedText, showHidden: showHiddenText, soundLabels: editor.project.captions.showSoundLabels)
        if signature != coordinator.signature {
            coordinator.signature = signature
            coordinator.rebuild(showDeleted: showDeletedText, showHidden: showHiddenText)
        }
        coordinator.highlightActive()
    }

    static func dismantleNSView(_ view: TranscriptNSTextView, coordinator: Coordinator) {
        coordinator.closePopover()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptNSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        nsView.textContainer?.containerSize = NSSize(width: max(width - TranscriptNSTextView.gutter, 1), height: .greatestFiniteMagnitude)
        guard let manager = nsView.layoutManager, let container = nsView.textContainer else { return nil }
        manager.ensureLayout(for: container)
        let height = manager.usedRect(for: container).height
        return CGSize(width: width, height: max(height, 40))
    }

    struct Signature: Equatable {
        var words: [TranscriptWord]
        var slices: [Slice]
        var showDeleted: Bool
        var showHidden: Bool
        var soundLabels: Bool
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: TranscriptNSTextView?
        var editor: EditorModel?
        var signature: Signature?
        /// Visible tokens with their character ranges, in text order.
        private(set) var ranges: [(token: TranscriptToken, range: NSRange)] = []
        private var activeRange: NSRange?
        /// What the highlights were last drawn for; nil after the text is rebuilt.
        private var highlightKey: HighlightKey?

        private struct HighlightKey: Equatable {
            var active: NSRange?
            var isPlayingWord: Bool
            var cutPreview: TranscriptCutPreview?
            var selection: NSRange
        }
        private var panel: TranscriptActionPanel?
        /// Hovering "Cut video" or "Cut transcript" colours what it would cut (`data-cut-preview`).
        var cutPreview: TranscriptCutPreview? { didSet { highlightActive() } }

        // MARK: Building

        func rebuild(showDeleted: Bool, showHidden: Bool) {
            guard let editor, let textView else { return }
            let tokens = editor.transcriptTokens
            let project = editor.project, resolver = editor.resolver
            let text = NSMutableAttributedString()
            let paragraph = NSMutableParagraphStyle()
            // `typo.copy` 13 px at line-height 1.75; 16 px between paragraphs.
            paragraph.minimumLineHeight = 13 * 1.75
            paragraph.maximumLineHeight = 13 * 1.75
            paragraph.paragraphSpacing = 16
            let base: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .baselineOffset: (13 * 1.75 - NSFont.systemFont(ofSize: 13).boundingRectForFont.height) / 4,
                .foregroundColor: NSColor(Theme.Colors.text),
                .paragraphStyle: paragraph,
            ]
            var newRanges: [(TranscriptToken, NSRange)] = []
            for para in TranscriptEditing.paragraphs(tokens) {
                var pieces: [(TranscriptToken, NSAttributedString)] = []
                for token in para {
                    if let piece = attributed(token, project: project, resolver: resolver, showDeleted: showDeleted, showHidden: showHidden, base: base) { pieces.append((token, piece)) }
                }
                guard !pieces.isEmpty else { continue }
                if text.length > 0 { text.append(NSAttributedString(string: "\n", attributes: base)) }
                for (i, (token, piece)) in pieces.enumerated() {
                    if i > 0 { text.append(NSAttributedString(string: " ", attributes: base)) }
                    newRanges.append((token, NSRange(location: text.length, length: piece.length)))
                    text.append(piece)
                }
            }
            let selection = textView.selectedRange()
            ranges = newRanges
            textView.textStorage?.setAttributedString(text)
            textView.setSelectedRange(NSRange(location: min(selection.location, text.length), length: 0))
            activeRange = nil
            highlightKey = nil
            textView.invalidateIntrinsicContentSize()
        }

        /// Word and pause styles.
        private func attributed(_ token: TranscriptToken, project: Project, resolver: TimeResolver, showDeleted: Bool, showHidden: Bool, base: [NSAttributedString.Key: Any]) -> NSAttributedString? {
            var attrs = base
            let present = resolver.isSourceRangePresent(token.sourceStartMs, token.sourceEndMs)
            if token.kind == .gap {
                let playDuration = resolver.sourceToPlayback(token.sourceEndMs) - resolver.sourceToPlayback(token.sourceStartMs)
                let deleted = playDuration < 50
                if deleted && !showDeleted { return nil }
                let tightened = !deleted && playDuration < token.sourceEndMs - token.sourceStartMs - 50
                let seconds = (tightened ? playDuration : token.sourceEndMs - token.sourceStartMs) / 1000
                attrs[.font] = NSFont.systemFont(ofSize: 13 * 0.85)
                attrs[.foregroundColor] = tightened ? NSColor.white.withAlphaComponent(Theme.secondaryOpacity) : NSColor(Theme.Colors.tertiary)
                // A capsule behind it, drawn by the text view.
                attrs[.transcriptChip] = tightened ? NSColor(Theme.Colors.primary).withAlphaComponent(0.15) : NSColor.white.withAlphaComponent(0.06)
                if deleted {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attrs[.foregroundColor] = NSColor(Theme.Colors.tertiary).withAlphaComponent(0.4)
                }
                attrs[.toolTip] = tightened
                    ? String(format: "Pause tightened to %.1fs (was %.1fs) — ⌘Z undoes", playDuration / 1000, (token.sourceEndMs - token.sourceStartMs) / 1000)
                    : "Pause — click to select, then tighten it to a natural breath"
                // 6 px of padding on each side: a zero-width space and the last glyph carry it as kern.
                let chip = NSMutableAttributedString(string: "\u{200B}" + String(format: "··· %.1fs", seconds), attributes: attrs)
                chip.addAttribute(.kern, value: TranscriptNSTextView.chipPadding, range: NSRange(location: 0, length: 1))
                chip.addAttribute(.kern, value: TranscriptNSTextView.chipPadding, range: NSRange(location: chip.length - 1, length: 1))
                return chip
            }
            if token.wordType == "sound-label" {
                if !project.captions.showSoundLabels { return nil }
                attrs[.foregroundColor] = NSColor(Theme.Colors.text).withAlphaComponent(Theme.secondaryOpacity)
            }
            if !present {
                if !showDeleted { return nil }
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.foregroundColor] = NSColor(Theme.Colors.text).withAlphaComponent(0.4)
            } else if token.isHidden {
                if !showHidden { return nil }
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue
                attrs[.foregroundColor] = NSColor(Theme.Colors.text).withAlphaComponent(0.45)
                attrs[.toolTip] = "Hidden from captions — the video still plays it"
            }
            if token.fillerTier == 1 {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                attrs[.underlineColor] = NSColor(Theme.Colors.primary)
            } else if token.fillerTier == 2 {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                attrs[.underlineColor] = NSColor(Theme.Colors.text).withAlphaComponent(Theme.secondaryOpacity)
            }
            return NSAttributedString(string: token.text, attributes: attrs)
        }

        // MARK: Active word, cut preview

        /// The playing word gets a primary 25% background only while playing, and is scrolled into
        /// view then (`isPlaying ? activeEl : null`). The gutter dot follows the playhead's token,
        /// playing or not.
        func highlightActive() {
            guard let editor, let textView, let manager = textView.layoutManager else { return }
            let t = editor.previewSourceTimeMs
            let active = ranges.first(where: { $0.token.sourceStartMs <= t && t <= $0.token.sourceEndMs })
            // Clearing the highlights redraws the whole text: only when they change. The dot
            // still follows the layout.
            let key = HighlightKey(active: active?.range, isPlayingWord: editor.isPlaying && active?.token.kind == .word, cutPreview: cutPreview, selection: textView.selectedRange())
            if key == highlightKey {
                if let active { textView.moveDot(to: active.range) }
                return
            }
            highlightKey = key
            let full = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
            manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            if let active {
                if editor.isPlaying && active.token.kind == .word {
                    manager.addTemporaryAttribute(.backgroundColor, value: NSColor(Theme.Colors.primary).withAlphaComponent(0.25), forCharacterRange: active.range)
                    if activeRange != active.range && !textView.recentlyScrolled { textView.scrollRangeToVisible(active.range) }
                }
                activeRange = active.range
                textView.moveDot(to: active.range)
            }
            if let cutPreview {
                for item in targets() where editor.isPresent(item) && (cutPreview == .video || (item.kind == .word && !item.isHidden)) {
                    if let r = ranges.first(where: { $0.token.id == item.id })?.range {
                        manager.addTemporaryAttribute(.foregroundColor, value: NSColor(Theme.Colors.dangerActiveText), forCharacterRange: r)
                    }
                }
            }
        }

        // MARK: Targets

        /// `coveredTokens` of a range (partly or fully).
        func tokens(in range: NSRange) -> [TranscriptToken] {
            ranges.filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.token)
        }

        /// The token at a caret position (inside or at its end).
        func token(atCaret location: Int) -> (token: TranscriptToken, range: NSRange)? {
            ranges.first { location >= $0.range.location && location <= NSMaxRange($0.range) }
        }

        /// `targetTokens`: the covered tokens, or the caret's token.
        func targets() -> [TranscriptToken] {
            guard let textView else { return [] }
            let selection = textView.selectedRange()
            if selection.length > 0 { return tokens(in: selection) }
            return token(atCaret: selection.location).map { [$0.token] } ?? []
        }

        // MARK: Editing

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard let editor, let text else { return false }
            if text.isEmpty {
                handleDelete(range, editor: editor)
            } else {
                handleInput(range, text: text, editor: editor)
            }
            return false
        }

        /// `handleDeleteInput`: inside a word edits its text; anything wider cuts the tokens out
        /// of the video (a cut token only moves the caret).
        private func handleDelete(_ range: NSRange, editor: EditorModel) {
            let covered = ranges.filter { NSIntersectionRange($0.range, range).length > 0 }
            if covered.count == 1, let item = covered.first, item.token.kind == .word,
               NSIntersectionRange(item.range, range) != item.range, let index = item.token.wordIndex {
                let local = NSRange(location: range.location - item.range.location, length: range.length)
                let newText = (item.token.text as NSString).replacingCharacters(in: local, with: "")
                editor.correctTranscript(from: index, to: index, text: newText)
                textView?.setSelectedRange(NSRange(location: range.location, length: 0))
                return
            }
            var targets = covered.map(\.token)
            if targets.isEmpty, let before = ranges.last(where: { NSMaxRange($0.range) <= range.location }) {
                // The separator before the caret: the adjacent token.
                targets = [before.token]
            }
            let present = targets.filter { editor.isPresent($0) }
            if present.isEmpty {
                textView?.setSelectedRange(NSRange(location: range.location, length: 0))
                return
            }
            editor.cutFromVideo(present)
        }

        /// `handleTextInput`: corrections; whitespace at a word boundary is ignored.
        private func handleInput(_ range: NSRange, text: String, editor: EditorModel) {
            if range.length > 0 {
                let words = ranges.filter { NSIntersectionRange($0.range, range).length > 0 && $0.token.kind == .word }
                guard let first = words.first, let last = words.last, let i0 = first.token.wordIndex, let i1 = last.token.wordIndex else { return }
                if words.count == 1 {
                    let local = NSRange(location: range.location - first.range.location, length: min(range.length, NSMaxRange(first.range) - range.location))
                    editor.correctTranscript(from: i0, to: i0, text: (first.token.text as NSString).replacingCharacters(in: local, with: text))
                } else {
                    editor.correctTranscript(from: i0, to: i1, text: text)
                }
                return
            }
            guard let item = token(atCaret: range.location), item.token.kind == .word, let index = item.token.wordIndex else { return }
            let offset = range.location - item.range.location
            if text.allSatisfy(\.isWhitespace) && (offset == 0 || offset == item.range.length) { return }
            editor.correctTranscript(from: index, to: index, text: (item.token.text as NSString).replacingCharacters(in: NSRange(location: offset, length: 0), with: text))
            textView?.setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Also fires while the text is rebuilt inside a SwiftUI update; place the bar after it.
            DispatchQueue.main.async { [weak self] in self?.updatePopover() }
        }

        // MARK: Floating action bar

        func updatePopover() {
            guard let editor, let textView else { return }
            let targets = targets()
            let pressed = NSEvent.pressedMouseButtons != 0
            guard !targets.isEmpty, textView.window?.firstResponder === textView, !pressed else {
                closePopover()
                return
            }
            // A dead key (´, ~, ¸) leaves marked text until the next key; wait for it.
            guard !textView.hasMarkedText() else { return }
            let selection = textView.selectedRange()
            guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
            manager.ensureLayout(for: container)
            var glyphs = manager.glyphRange(forCharacterRange: selection.length > 0 ? selection : NSRange(location: max(selection.location - 1, 0), length: 1), actualCharacterRange: nil)
            if glyphs.length == 0 { glyphs.length = 1 }
            var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            rect = rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            guard let window = textView.window, rect.intersects(textView.visibleRect) else {
                closePopover()
                return
            }
            let bar = TranscriptActionBar(editor: editor, targets: targets, onCutPreview: { [weak self] in self?.cutPreview = $0 }, onDone: { [weak self] in
                self?.closePopover()
            })
            // Popover to the left (`placement:"left"`, offset 16) of a 1 px anchor at the text's
            // left edge, centred on the selection.
            let anchor = window.convertToScreen(textView.convert(NSRect(x: textView.textContainerOrigin.x, y: rect.midY, width: 1, height: 0), to: nil))
            let panel = self.panel ?? TranscriptActionPanel()
            self.panel = panel
            panel.show(bar, rightEdge: anchor.minX - 16, centerY: anchor.midY, in: window)
        }

        func closePopover() {
            panel?.dismiss()
            if cutPreview != nil { cutPreview = nil }
        }
    }
}

/// The text view: hover scrubs, click seeks, ⌘⌫ cuts from the transcript, Esc clears.
extension NSAttributedString.Key {
    /// Fill of a pause chip's capsule.
    static let transcriptChip = NSAttributedString.Key("regrava.transcriptChip")
}

enum TranscriptCutPreview { case video, transcript }

final class TranscriptNSTextView: NSTextView {
    weak var coordinator: TranscriptTextEditor.Coordinator?
    private var downLocation: NSPoint?
    /// Left inset holding the dot; the text starts after it (`padding-left: 14`).
    static let gutter: CGFloat = 14
    static let chipPadding: CGFloat = 6
    private let dot = CALayer()
    private var dotY: CGFloat?
    private var lastWheel = Date.distantPast

    /// No auto-scroll for 2 s after the user scrolled.
    var recentlyScrolled: Bool { Date().timeIntervalSince(lastWheel) < 2 }

    override var textContainerOrigin: NSPoint { NSPoint(x: Self.gutter, y: 0) }

    override func scrollWheel(with event: NSEvent) {
        lastWheel = Date()
        super.scrollWheel(with: event)
    }

    /// The 5 px white dot at the gutter's left, beside the playhead's line (+1 px), moved on a
    /// 430/30/1 spring; it keeps its place when no token is active.
    func moveDot(to range: NSRange) {
        guard let manager = layoutManager, let container = textContainer, range.location < (textStorage?.length ?? 0) else { return }
        let glyph = manager.glyphIndexForCharacter(at: range.location)
        let line = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        _ = container
        let y = line.midY + textContainerOrigin.y + 1
        if dot.superlayer == nil {
            wantsLayer = true
            dot.backgroundColor = NSColor.white.cgColor
            dot.cornerRadius = 2.5
            dot.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
            dot.zPosition = 10
            layer?.addSublayer(dot)
        }
        guard y != dotY else { return }
        let target = CGPoint(x: 2.5, y: y)
        if dotY == nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.position = target
            CATransaction.commit()
        } else {
            let spring = CASpringAnimation(keyPath: "position")
            spring.stiffness = 430
            spring.damping = 30
            spring.mass = 1
            spring.fromValue = dot.presentation()?.position ?? dot.position
            spring.toValue = target
            spring.duration = spring.settlingDuration
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.position = target
            CATransaction.commit()
            dot.add(spring, forKey: "position")
        }
        dotY = y
    }

    /// Pause chips: a capsule 6 px wider than the text on each side.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer else { return }
        storage.enumerateAttribute(.transcriptChip, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { box, _ in
                var capsule = box.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                capsule = capsule.insetBy(dx: 0, dy: (capsule.height - 16) / 2)
                color.setFill()
                NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["transcript"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: ["transcript": true]))
    }

    private func characterIndex(_ event: NSEvent) -> Int? {
        guard let manager = layoutManager, let container = textContainer else { return nil }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        var fraction: CGFloat = 0
        let glyph = manager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        return manager.characterIndexForGlyph(at: glyph)
    }

    /// Hover over a word scrubs to that moment of it (not while playing or dragging).
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let coordinator, let editor = coordinator.editor, !editor.isPlaying, NSEvent.pressedMouseButtons == 0,
              let index = characterIndex(event), let item = coordinator.ranges.first(where: { NSLocationInRange(index, $0.range) }), item.token.kind == .word else { return }
        let fraction = Double(index - item.range.location) / Double(max(item.range.length, 1))
        let source = item.token.sourceStartMs + 1 + (item.token.sourceEndMs - item.token.sourceStartMs - 1) * fraction
        guard editor.project.resolver.isSourceTimePresent(source) else { return }
        editor.scrub(to: editor.project.resolver.sourceToPlayback(source))
        coordinator.highlightActive()
    }

    /// Leaving the text snaps the dot back to the playhead.
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        coordinator?.editor?.endScrub()
        coordinator?.highlightActive()
    }

    override func mouseDown(with event: NSEvent) {
        downLocation = event.locationInWindow
        super.mouseDown(with: event)
        // NSTextView tracks the drag inside mouseDown; this runs after the button is released.
        let moved = downLocation.map { hypot($0.x - event.locationInWindow.x, $0.y - event.locationInWindow.y) } ?? 0
        if moved <= 4, let coordinator, let editor = coordinator.editor, let first = coordinator.targets().first {
            editor.endScrub()
            let source = first.sourceStartMs + 1
            if editor.project.resolver.isSourceTimePresent(source) { editor.seek(to: editor.project.resolver.sourceToPlayback(source)) }
        }
        coordinator?.updatePopover()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.keyCode, flags) {
        case (51, [.command]): // ⌘⌫
            if let coordinator, let editor = coordinator.editor { editor.cutFromTranscript(coordinator.targets()) }
        case (53, []): // Esc
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
            coordinator?.closePopover()
        case (48, _): break // Tab
        case (6, [.command]): coordinator?.editor?.undo()
        case (6, [.command, .shift]): coordinator?.editor?.redo()
        default: super.keyDown(with: event)
        }
    }

    /// Copies the covered words joined by spaces.
    override func copy(_ sender: Any?) {
        guard let coordinator else { return }
        let text = coordinator.tokens(in: selectedRange()).filter { $0.kind == .word }.map(\.text).joined(separator: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func cut(_ sender: Any?) {
        copy(sender)
        deleteBackward(sender)
    }

    override func resignFirstResponder() -> Bool {
        coordinator?.closePopover()
        return super.resignFirstResponder()
    }
}

/// The floating bar's arrowless glass panel, left of the transcript, over the canvas.
@MainActor
final class TranscriptActionPanel {
    private var window: NSPanel?
    private var host: NSHostingView<AnyView>?

    func show(_ bar: TranscriptActionBar, rightEdge: CGFloat, centerY: CGFloat, in parent: NSWindow) {
        let content = AnyView(bar.environment(\.colorScheme, .dark))
        let isNew = window == nil
        if window == nil {
            let host = NSHostingView(rootView: content)
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.contentView = host
            panel.appearance = NSAppearance(named: .darkAqua)
            window = panel
            self.host = host
        } else {
            host?.rootView = content
        }
        guard let window, let host else { return }
        let size = host.fittingSize
        // 40 px clear of the window's top and bottom.
        let frame = parent.frame
        let y = min(max(centerY - size.height / 2, frame.minY + 40), frame.maxY - 40 - size.height)
        window.setFrame(NSRect(x: rightEdge - size.width, y: y, width: size.width, height: size.height), display: true)
        if window.parent !== parent {
            window.parent?.removeChildWindow(window)
            parent.addChildWindow(window, ordered: .above)
        }
        if isNew || !window.isVisible {
            window.alphaValue = 0
            window.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().alphaValue = 1
            }
        }
    }

    func dismiss() {
        guard let window else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }
}

/// One row of the bar: transparent, 38 px, padX 12, radius 6, hover white 8% (primary for Tighten).
private struct TranscriptBarRow: View {
    var title: String
    var icon: String
    var isPrimary = false
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.gap(1)) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 20)
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(isPrimary ? Theme.Colors.primary : Color(hex: 0xFFFFFF, opacity: hovered ? 0x14 / 255 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Colors.text)
        .onHover { hovered = $0 }
    }
}

/// Buttons of the floating bar: Tighten pause / Cut video, Cut transcript, Restore, Play;
/// tooltips on the left, ⌘⌫ only in Cut transcript's tooltip.
struct TranscriptActionBar: View {
    @ObservedObject var editor: EditorModel
    var targets: [TranscriptToken]
    var onCutPreview: (TranscriptCutPreview?) -> Void
    var onDone: () -> Void

    var body: some View {
        let project = editor.project
        let present = targets.filter { TranscriptEditing.isPresent($0, in: project) }
        let onlyGaps = !targets.contains { $0.kind == .word }
        let canTighten = onlyGaps && targets.contains { TranscriptEditing.canTighten($0, in: project) && TranscriptEditing.isPresent($0, in: project) }
        let canCutVideo = !present.isEmpty
        let canCutTranscript = targets.contains { $0.kind == .word && !$0.isHidden && TranscriptEditing.isPresent($0, in: project) }
        let canRestore = targets.contains { !TranscriptEditing.isPresent($0, in: project) || $0.isHidden }
        VStack(alignment: .leading, spacing: 5.7) {
            if canTighten {
                let n = targets.filter { $0.kind == .gap }.count
                TranscriptBarRow(title: n == 1 ? "Tighten pause" : "Tighten \(n) pauses", icon: "timeline.selection", isPrimary: true) {
                    editor.cutFromVideo(targets)
                    onDone()
                }
                .tooltip("Shorten this pause, keeping a natural breath on each side", placement: .left)
            } else if canCutVideo {
                TranscriptBarRow(title: "Cut video", icon: "scissors") {
                    onCutPreview(nil)
                    editor.cutFromVideo(targets)
                    onDone()
                }
                .tooltip("Cut this part out of the video", placement: .left)
                .onHover { onCutPreview($0 ? .video : nil) }
            }
            if canCutTranscript {
                TranscriptBarRow(title: "Cut transcript", icon: "text.badge.minus") {
                    onCutPreview(nil)
                    editor.cutFromTranscript(targets)
                    onDone()
                }
                .tooltip("Cut this part from the transcript and captions only — the video is unchanged, and Restore brings it back", shortcut: "⌘⌫", placement: .left)
                .onHover { onCutPreview($0 ? .transcript : nil) }
            }
            if canRestore {
                TranscriptBarRow(title: "Restore", icon: "arrow.uturn.backward") {
                    editor.restore(targets)
                    onDone()
                }
                .tooltip("Bring this part back into the video and captions", placement: .left)
            }
            TranscriptBarRow(title: "Play", icon: "play.fill") { editor.audition(targets) }
                .tooltip("Play this part once", placement: .left)
        }
        .padding(6)
        .fixedSize()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}
