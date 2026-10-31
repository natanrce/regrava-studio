import Foundation

// Captions: config, line segmentation and per-frame layout.

/// Project config key `captions`.
public struct CaptionsConfig: Codable, Hashable, Sendable {
    public enum Font: String, Codable, CaseIterable, Sendable { case sansSerif = "sans-serif", serif, mono }
    public enum WordsReveal: String, Codable, CaseIterable, Sendable { case lineByLine = "line-by-line", wordByWord = "word-by-word" }
    public enum LineGrowth: String, Codable, CaseIterable, Sendable { case entireLine = "entire-line", leftAnchored = "left-anchored", centered }
    public enum WordEntrance: String, Codable, CaseIterable, Sendable { case appear, fadeIn = "fade-in", slideIn = "slide-in" }

    public var enableTranscript = true
    public var showSoundLabels = false
    public var font = Font.sansSerif
    public var sizeRatio = 0.05
    public var color = "#ffffff"
    public var backgroundColor = "#000000"
    public var position01 = Vec2(0.5, 1)
    public var wordsReveal = WordsReveal.lineByLine
    public var lineGrowth = LineGrowth.leftAnchored
    public var wordEntrance = WordEntrance.appear
    /// Keyboard shortcuts overlay ("Show shortcuts").
    public var enableShortcuts = false
    /// Presses the user hid, keyed by `String(firstKeyDownMs)`; showing one deletes its key.
    public var hiddenShortcuts: [String: Bool] = [:]
    public var showShortcutsWithSingleLetters = false
    /// Key row height over the stage height (slider 0.075…0.25).
    public var shortcutsSizeRatio = 0.1

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptionsConfig()
        enableTranscript = c.value(.enableTranscript, default: d.enableTranscript)
        showSoundLabels = c.value(.showSoundLabels, default: d.showSoundLabels)
        font = c.value(.font, default: d.font)
        sizeRatio = c.value(.sizeRatio, default: d.sizeRatio)
        color = c.value(.color, default: d.color)
        let background: String = c.value(.backgroundColor, default: d.backgroundColor)
        backgroundColor = RGBA(hexString: background) == nil ? d.backgroundColor : background
        position01 = c.value(.position01, default: d.position01)
        wordsReveal = c.value(.wordsReveal, default: d.wordsReveal)
        lineGrowth = c.value(.lineGrowth, default: d.lineGrowth)
        wordEntrance = c.value(.wordEntrance, default: d.wordEntrance)
        enableShortcuts = c.value(.enableShortcuts, default: d.enableShortcuts)
        hiddenShortcuts = c.value(.hiddenShortcuts, default: d.hiddenShortcuts)
        showShortcutsWithSingleLetters = c.value(.showShortcutsWithSingleLetters, default: d.showShortcutsWithSingleLetters)
        shortcutsSizeRatio = c.value(.shortcutsSizeRatio, default: d.shortcutsSizeRatio)
    }

    /// `isDark()` of the background (YIQ < 128): the panel's "Dark" / "Light" colour.
    public var isDark: Bool {
        guard let c = RGBA(hexString: backgroundColor) else { return true }
        let yiq: Double = (299 * c.r + 587 * c.g + 114 * c.b) * 255 / 1000
        return yiq < 128
    }
}

/// A caption line: words with their measured sizes.
public struct CaptionLine: Hashable, Sendable {
    public struct Word: Hashable, Sendable {
        public var text: String
        public var startMs: Double
        public var endMs: Double
        public var width: Double
        public var height: Double
    }

    public var words: [Word]
    public var offsets: [Double]
    public var maxHeights: [Double]
    public var startMs: Double { words[0].startMs }
    public var endMs: Double { words[words.count - 1].endMs }
    public var totalWidth: Double { offsets[words.count] }
    public var maxWordHeight: Double { maxHeights[words.count] }

    /// First word trimmed; others " " + trimmed (the last also trimmed at the end), sized with
    /// the space's measured width.
    init(_ items: [TranscriptWord], measure: (String) -> Size2) {
        let space = measure(" ").width
        words = items.enumerated().map { i, w in
            var t = String(w.text.drop { $0.isWhitespace })
            if i == 0 {
                let size = measure(t)
                return Word(text: t, startMs: w.startMs, endMs: w.endMs, width: size.width, height: size.height)
            }
            if i == items.count - 1 { t = t.trimmingCharacters(in: .whitespacesAndNewlines) }
            let size = measure(t)
            return Word(text: " " + t, startMs: w.startMs, endMs: w.endMs, width: size.width + space, height: size.height)
        }
        offsets = [0]
        maxHeights = [0]
        for w in words {
            offsets.append(offsets.last! + w.width)
            maxHeights.append(max(maxHeights.last!, w.height))
        }
    }
}

public enum CaptionLayout {
    static let maxChars = 42
    static let maxGapFromFirstEndMs = 1000.0
    static let maxLineSpanMs = 7000.0
    static let endExtendMs = 300.0

    /// `measure` returns the text box including padding.
    public static func lines(_ words: [TranscriptWord], maxWidth: Double, measure: (String) -> Size2) -> [CaptionLine] {
        let space = measure(" ").width
        var groups: [[TranscriptWord]] = []
        var current: [TranscriptWord] = []
        var chars = 0
        var width = 0.0
        for w in words {
            let ww = measure(w.text).width
            let has = !current.isEmpty
            let tooManyChars = chars + w.text.utf16.count > maxChars
            let tooWide = width + (has ? space : 0) + ww > maxWidth
            let tooLong = has && w.endMs - current[0].startMs > maxLineSpanMs
            let tooFar = has && w.startMs - current[0].endMs > maxGapFromFirstEndMs
            if tooManyChars || tooWide || tooLong || tooFar {
                if !has { continue }
                groups.append(current)
                current = [w]
                chars = w.text.utf16.count
                width = ww
                continue
            }
            current.append(w)
            chars += w.text.utf16.count
            width += ww
        }
        if !current.isEmpty { groups.append(current) }
        var lines = groups.map { CaptionLine($0, measure: measure) }
        for i in lines.indices {
            let next = i + 1 < lines.count ? lines[i + 1].startMs : .infinity
            lines[i].words[lines[i].words.count - 1].endMs = min(lines[i].endMs + endExtendMs, next)
        }
        return lines
    }

    static func state(_ t: Double, _ s: Double, _ e: Double) -> Int { t < s ? -1 : t > e ? 1 : 0 }
    static func interp(_ p: Int, _ before: Double, _ during: Double, _ after: Double) -> Double { p == -1 ? before : p == 1 ? after : during }

    /// Index of the last element with key <= v, nil when none.
    static func lastAtOrBefore(_ count: Int, _ v: Double, key: (Int) -> Double) -> Int? {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if key(mid) <= v { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }

    /// The line shown at `t` (the nearer one in a gap).
    public static func activeLine(_ lines: [CaptionLine], at t: Double) -> Int {
        guard let i = lastAtOrBefore(lines.count, t, key: { lines[$0].startMs }) else { return 0 }
        let g = lines[i]
        if g.endMs < t { return i }
        guard i + 1 < lines.count else { return i }
        return t - g.endMs < lines[i + 1].startMs - t ? i : i + 1
    }
}

/// Where a line's box and words want to be at `t`.
public struct CaptionFrame {
    let line: CaptionLine
    let config: CaptionsConfig
    let stage: Rect2
    let t: Double
    let presentWordCount: Int
    let progress: Int

    public init(line: CaptionLine, config: CaptionsConfig, stage: Rect2, t: Double) {
        self.line = line
        self.config = config
        self.stage = stage
        self.t = t
        presentWordCount = (CaptionLayout.lastAtOrBefore(line.words.count, t) { line.words[$0].startMs } ?? -1) + 1
        progress = CaptionLayout.state(t, line.words[0].startMs, line.words[line.words.count - 1].endMs)
    }

    private var currentWord: CaptionLine.Word { presentWordCount > 0 ? line.words[presentWordCount - 1] : line.words[0] }
    private var paddedStage: Rect2 { stage.padByRatio(-0.1) }

    private var lineGrowth: CaptionsConfig.LineGrowth { config.wordEntrance == .fadeIn ? .entireLine : config.lineGrowth }

    private func fit(_ w: Double, _ h: Double) -> Rect2 {
        Rect2(x: 0, y: 0, width: w, height: h).fitInside(paddedStage, anchor: config.position01)
    }

    func wordProgress(_ i: Int) -> Int { progress != 0 ? progress : CaptionLayout.state(t, line.words[i].startMs, line.words[i].endMs) }

    /// `getRect`.
    public var rect: Rect2 {
        if config.wordsReveal == .wordByWord { return fit(currentWord.width, currentWord.height) }
        let full = fit(line.totalWidth, line.maxWordHeight)
        switch lineGrowth {
        case .entireLine: return full
        case .leftAnchored: return Rect2(x: full.x, y: full.y, width: line.offsets[presentWordCount], height: full.height)
        case .centered:
            let n = presentWordCount
            return fit(line.offsets[n], n > 0 ? line.maxHeights[n] : line.words[0].height)
        }
    }

    /// `getWordRect`, relative to the box origin.
    public func wordRect(_ i: Int, slidePx: Double) -> Rect2 {
        let w = line.words[i]
        var x = line.offsets[i]
        if config.wordsReveal == .wordByWord {
            let ws = CaptionLayout.state(t, w.startMs, w.endMs)
            x = progress == 1 || ws == 1 ? -w.width : ws == 0 ? 0 : currentWord.width
        } else if config.wordEntrance == .slideIn {
            x = CaptionLayout.interp(wordProgress(i), line.offsets[i] + slidePx, line.offsets[i], line.offsets[i])
        }
        return Rect2(x: x, y: 0, width: w.width, height: w.height)
    }

    /// `getWordOpacity`.
    public func wordOpacity(_ i: Int) -> Double {
        if progress != 0 { return 0 }
        let p = wordProgress(i)
        if config.wordsReveal == .wordByWord { return CaptionLayout.interp(p, 0, 1, 0) }
        if config.wordEntrance == .fadeIn { return CaptionLayout.interp(p, 0.5, 1, 1) }
        return CaptionLayout.interp(p, 0, 1, 1)
    }

    public var opacity: Double { CaptionLayout.interp(progress, 0, 1, 0) }
}

/// What to draw for captions at one instant.
public struct CaptionScene: Sendable {
    public struct Box: Sendable {
        public var rect: Rect2
        public var opacity: Double
    }

    public struct Word: Sendable {
        /// Line and word index: the same word from one frame to the next.
        public var id: Int
        public var text: String
        public var rect: Rect2
        public var opacity: Double
    }

    public var box: Box?
    public var words: [Word] = []
}

/// Captions over time: line targets sprung (springs reset to the targets 1 s earlier, then
/// advanced frame by frame, +, 10909-11158).
public struct CaptionTrack: Sendable {
    public static let spring = SpringConfig(stiffness: 425, damping: 12, mass: 1.5, clampOvershoot: true, precision: 0.002)
    static let influenceMs = 1000.0
    static let slidePx = 40.0

    public let lines: [CaptionLine]
    let config: CaptionsConfig
    let stage: Rect2
    let fontSize: Double
    /// Stage units per 1080-high stage pixel (for the 40 px slide).
    let unit: Double
    let resolver: TimeResolver
    public let fps: Double
    /// Largest `endMs` of the lines up to each index, when the lines are ordered by start
    /// (nil otherwise): bounds the lines near an instant without visiting all of them.
    private let maxEndThrough: [Double]?

    public init(lines: [CaptionLine], config: CaptionsConfig, stage: Rect2, resolver: TimeResolver, fps: Double) {
        self.lines = lines
        self.config = config
        self.stage = stage
        fontSize = stage.shortestSide * config.sizeRatio
        unit = stage.height / 1080
        self.resolver = resolver
        self.fps = max(fps, 1)
        var maxEnd: [Double] = []
        maxEnd.reserveCapacity(lines.count)
        var sorted = true
        for (i, line) in lines.enumerated() {
            if i > 0 && line.startMs < lines[i - 1].startMs { sorted = false; break }
            maxEnd.append(max(maxEnd.last ?? -.infinity, line.endMs))
        }
        maxEndThrough = sorted ? maxEnd : nil
    }

    /// Indices, ascending, of the lines within `influenceMs` of `t`.
    func influencingLines(at t: Double) -> [Int] {
        let influence = Self.influenceMs
        func near(_ i: Int) -> Bool { t >= lines[i].startMs - influence && t <= lines[i].endMs + influence }
        guard let maxEnd = maxEndThrough else { return lines.indices.filter(near) }
        guard let last = lastSearch(count: lines.count, while: { t >= lines[$0].startMs - influence }) else { return [] }
        var result: [Int] = []
        var i = last
        while i >= 0 && t <= maxEnd[i] + influence {
            if near(i) { result.append(i) }
            i -= 1
        }
        return result.reversed()
    }

    private struct Targets {
        var box: CaptionScene.Box?
        var words: [Int: (text: String, rect: Rect2, opacity: Double)] = [:]
    }

    private func targets(atSource t: Double) -> Targets {
        guard !lines.isEmpty else { return Targets() }
        var out = Targets()
        let active = CaptionLayout.activeLine(lines, at: t)
        let act = CaptionFrame(line: lines[active], config: config, stage: stage, t: t)
        let r = act.rect
        // `pad({x: 0.5·fontSize, y: 0.25·fontSize})`.
        out.box = .init(rect: Rect2(x: r.x - 0.5 * fontSize, y: r.y - 0.25 * fontSize, width: r.width + fontSize, height: r.height + 0.5 * fontSize), opacity: act.opacity)
        for li in influencingLines(at: t) {
            let line = lines[li]
            let own = li == active ? act : CaptionFrame(line: line, config: config, stage: stage, t: t)
            for wi in line.words.indices {
                var rect = own.wordRect(wi, slidePx: Self.slidePx * unit)
                rect.x += r.x
                rect.y += r.y
                out.words[li * 10_000 + wi] = (line.words[wi].text, rect, own.wordOpacity(wi))
            }
        }
        return out
    }

    private struct NodeState {
        var x: SpringValue, y: SpringValue, opacity: SpringValue
        init(_ rect: Rect2, _ opacity: Double) {
            x = SpringValue(rect.x)
            y = SpringValue(rect.y)
            self.opacity = SpringValue(opacity)
        }
        mutating func advance(toward rect: Rect2, opacity target: Double, ms: Double) {
            x.advance(toward: rect.x, config: CaptionTrack.spring, milliseconds: ms)
            y.advance(toward: rect.y, config: CaptionTrack.spring, milliseconds: ms)
            opacity.advance(toward: target, config: CaptionTrack.spring, milliseconds: ms)
        }
    }

    /// The scene at a playback time.
    public func scene(atPlayback time: Double) -> CaptionScene {
        guard !lines.isEmpty else { return CaptionScene() }
        let step = 1000 / fps
        let steps = Int((Self.influenceMs / step).rounded())
        var box: NodeState?
        var nodes: [Int: NodeState] = [:]
        var last = Targets()
        for k in 0...steps {
            let playback = time - Double(steps - k) * step
            last = targets(atSource: resolver.playbackToSource(max(playback, 0)))
            if let target = last.box {
                if box == nil { box = NodeState(target.rect, target.opacity) } else { box!.advance(toward: target.rect, opacity: target.opacity, ms: step) }
            }
            for (key, word) in last.words {
                if nodes[key] == nil { nodes[key] = NodeState(word.rect, word.opacity) } else { nodes[key]!.advance(toward: word.rect, opacity: word.opacity, ms: step) }
            }
        }
        var scene = CaptionScene()
        if let target = last.box, let state = box {
            // Width and height are not sprung (instant).
            scene.box = .init(rect: Rect2(x: state.x.value, y: state.y.value, width: target.rect.width, height: target.rect.height), opacity: clamp(state.opacity.value, 0, 1))
        }
        for key in last.words.keys.sorted() {
            guard let word = last.words[key], let state = nodes[key] else { continue }
            scene.words.append(.init(id: key, text: word.text, rect: Rect2(x: state.x.value, y: state.y.value, width: word.rect.width, height: word.rect.height), opacity: clamp(state.opacity.value, 0, 1)))
        }
        return scene
    }
}
