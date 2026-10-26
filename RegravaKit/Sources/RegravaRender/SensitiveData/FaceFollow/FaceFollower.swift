import CoreGraphics
import CoreVideo
import Foundation

extension SD {
    /// Follows the sighted faces of one stretch of video frame by frame, turning sightings into tracks.
    final class FaceFollower {
        typealias Track = SD.FaceTrack

        /// A face finding of a read.
        struct Sighting {
            let timeMs: Int
            let rect: CGRect
        }

        /// A read whose photo regions were searched for faces, with what it found.
        struct FaceSearch {
            let timeMs: Int
            let region: CGRect
            let faces: [CGRect]
        }

        typealias Active = (face: FollowedFace, startMs: Double, before: [(timeMs: Double, point: CGPoint)], isLostAtStart: Bool)

        let scanner: Scanner
        let timeline: ChangeTimeline
        let sampledTimesMs: [Int]
        let sightings: [Sighting]
        let searches: [FaceSearch]
        let endMs: Int
        let lock = NSLock()
        var decodedFrames = 0
        var followedFrames = 0

        init(scanner: Scanner, observations: [Observation], timeline: ChangeTimeline, sampledTimesMs: [Int], endMs: Int) {
            self.scanner = scanner
            self.timeline = timeline
            self.sampledTimesMs = sampledTimesMs
            self.endMs = endMs
            var sightings: [Sighting] = []
            for observation in observations {
                sightings.append(contentsOf: observation.findings.filter { $0.kind == "face" }.map { Sighting(timeMs: observation.timeMs, rect: $0.rect) })
            }
            sightings.sort { $0.timeMs < $1.timeMs }
            self.sightings = sightings
            var searches = observations.filter { !$0.faceRegion.isNull }.map { observation in
                FaceSearch(timeMs: observation.timeMs, region: observation.faceRegion,
                           faces: observation.findings.filter { $0.kind == "face" }.map { $0.rect })
            }
            searches.sort { $0.timeMs < $1.timeMs }
            self.searches = searches
        }

        /// The vertical scroll measured under `rect` between two times (positive when content moves down),
        /// or nil when a sample in between has no measurement for that stripe.
        func scrollDy(under rect: CGRect, fromMs: Double, toMs: Double) -> CGFloat? {
            let stripe = scanner.grid.stripe(ofX: rect.midX)
            let lowMs = Int((toMs < fromMs ? toMs : fromMs).rounded(.up))
            let highMs = Int((fromMs <= toMs ? toMs : fromMs).rounded(.up))
            let samples = timeline.samples
            var low = 0
            var high = samples.count
            while low < high {
                let mid = (low + high) / 2
                if samples[mid].timeMs <= lowMs { low = mid + 1 } else { high = mid }
            }
            var dy: CGFloat = 0
            var i = low
            while i < samples.count {
                let sample = samples[i]
                if highMs < sample.timeMs { break }
                if sample.isEverything { return nil }
                if sample.stripeShiftsPx.isEmpty { return nil }
                let shift = sample.stripeShiftsPx[stripe]
                if shift == Int16.min { return nil }
                dy = dy + Double(Int32(shift)) * -0.125
                i += 1
            }
            if toMs < fromMs { dy = -dy }
            return dy
        }

        /// The first sampled time at or after `atOrAfter`.
        func sampleTime(atOrAfter ms: Int) -> Int? {
            var low = 0
            var high = sampledTimesMs.count
            while low < high {
                let mid = (low + high) / 2
                if sampledTimesMs[mid] < ms { low = mid + 1 } else { high = mid }
            }
            return low < sampledTimesMs.count ? sampledTimesMs[low] : nil
        }

        func follow(pieceStartMs: Int, pieceEndMs: Int) -> [Track] {
            guard sightings.contains(where: { pieceStartMs <= $0.timeMs && $0.timeMs < pieceEndMs }) else { return [] }
            return follow(piece: (pieceStartMs, pieceEndMs))
        }

        // MARK: Following one piece

        func follow(piece: (startMs: Int, endMs: Int)) -> [Track] {
            let grid = scanner.grid
            let widthPx = grid.widthPx
            let heightPx = grid.heightPx
            var fromMs = Double(piece.startMs) + -1200
            if !(fromMs >= 0) { fromMs = 0 }
            var nextSighting = sightings.firstIndex { piece.startMs <= $0.timeMs } ?? sightings.count
            var nextSearch = searches.firstIndex { piece.startMs <= $0.timeMs } ?? searches.count
            var decoded = 0
            var followed = 0
            var active: [Active] = []
            var lost: [FollowedFace] = []
            var tracks: [Track] = []
            let pieceEnd = Double(piece.endMs)
            let followerEnd = Double(endMs)

            func changedSinceUnchanged(_ face: FollowedFace, upToMs: Int) -> Bool {
                timeline.changes(inAnyOf: grid.tiles(in: face.rect), afterMs: face.unchangedUpToMs, upToMs: upToMs) != nil
            }
            /// Whether a lost face's area changed between its last known state and the sample at `atMs`.
            func mayHaveReturned(_ face: FollowedFace, atMs ms: Int) -> Bool {
                guard let s = sampleTime(atOrAfter: ms), face.unchangedUpToMs < s else { return false }
                return changedSinceUnchanged(face, upToMs: s)
            }
            func isNeeded(_ t: Double) -> Bool {
                if !active.isEmpty { return true }
                if t < pieceEnd {
                    let ms = Int(t.rounded(.up))
                    for face in lost where mayHaveReturned(face, atMs: ms) { return true }
                }
                if nextSighting < sightings.count {
                    let ms = sightings[nextSighting].timeMs
                    if ms < piece.endMs { return Double(ms) - t <= 1200 }
                }
                return false
            }
            func makeTrack(_ a: Active, endMs: Double, isLostAtEnd: Bool) -> Track {
                var all = a.before
                all.append(contentsOf: a.face.path)
                return Track(startMs: a.startMs, endMs: endMs, path: all.filter { $0.timeMs <= endMs },
                             boxes: a.face.boxes.filter { $0.timeMs <= endMs }, isLostAtStart: a.isLostAtStart, isLostAtEnd: isLostAtEnd)
            }
            func keepLost(_ face: FollowedFace) {
                lost.append(face)
                if lost.count > 64 { lost.removeFirst() }
            }
            func finish(_ index: Int, endMs: Double, mayComeBack: Bool) {
                let a = active[index]
                tracks.append(makeTrack(a, endMs: endMs, isLostAtEnd: mayComeBack))
                active.remove(at: index)
                if mayComeBack {
                    a.face.unchangedUpToMs = sampleTime(atOrAfter: Int(endMs.rounded(.up))) ?? Int(endMs)
                    keepLost(a.face)
                }
            }
            var recent: [HalfFrame] = []
            func followBack(_ face: FollowedFace) -> (startMs: Double, path: [(timeMs: Double, point: CGPoint)], isLost: Bool) {
                let back = FollowedFace(continuing: face)
                for frame in recent.reversed() where frame.timeMs < face.timeMs {
                    followed += 1
                    let dy = scrollDy(under: back.rect, fromMs: back.timeMs, toMs: frame.timeMs)
                    if !back.follow(to: frame, scrollDy: dy) {
                        return (back.timeMs, Array(back.path.reversed().dropLast()), true)
                    }
                }
                if back.timeMs > 33.333333333333336 {
                    let extra = back.extrapolateBack(frameRect: CGRect(x: 0, y: 0, width: Double(widthPx), height: Double(heightPx)))
                    var all = back.path
                    all.append(contentsOf: extra.path)
                    return (extra.startMs, Array(all.reversed().dropLast()), false)
                }
                return (0, Array(back.path.reversed().dropLast()), false)
            }

            /// A new sighting whose followed-back path shows it came out of an active face that no longer
            /// looks as when seen: that face ends where their paths parted.
            func endFacesTakenOver(by face: FollowedFace, before: [(timeMs: Double, point: CGPoint)], at t: Double, in half: HalfFrame) {
                var j = active.count
                while j != 0 {
                    j -= 1
                    let other = active[j].face
                    guard let now = other.rect(atMs: t, along: []), SD.intersectionOverUnion(now, face.rect) < 0.1, !before.isEmpty else { continue }
                    var hasOverlapped = false
                    var partedMs = 0.0
                    var isUnparted = true
                    var endsOverlapping = false
                    for (k, p) in before.enumerated() {
                        guard let mine = face.rect(atMs: p.timeMs, along: before), let theirs = other.rect(atMs: p.timeMs, along: []) else { continue }
                        if SD.intersectionOverUnion(mine, theirs) >= 0.3 {
                            hasOverlapped = true
                            partedMs = 0
                            isUnparted = true
                            if k == before.count - 1 { endsOverlapping = true }
                            continue
                        }
                        if hasOverlapped && isUnparted {
                            partedMs = p.timeMs
                            isUnparted = false
                        }
                    }
                    if endsOverlapping { continue }
                    if !isUnparted && !other.looksAsWhenSeen(in: half) {
                        finish(j, endMs: partedMs, mayComeBack: false)
                    }
                }
            }

            restart: while true {
                recent = []
                let frames = scanner.makeChunkFrames(purpose: "sensitive data faces", startMs: Int(fromMs), endMs: endMs)
                frameLoop: while true {
                    guard let (buffer, t, _) = frames.next(isNeeded: isNeeded) else { break restart }
                    let tc = t.rounded(.up)
                    if !(tc < pieceEnd) && active.isEmpty { break restart }
                    if fromMs > t { continue frameLoop }
                    if active.isEmpty {
                        var isWanted = false
                        if t < pieceEnd {
                            for face in lost where mayHaveReturned(face, atMs: Int(tc)) {
                                isWanted = true
                                break
                            }
                        }
                        if !isWanted, nextSighting < sightings.count, sightings[nextSighting].timeMs < piece.endMs {
                            isWanted = !(Double(sightings[nextSighting].timeMs) - t > 1200)
                        }
                        if !isWanted { continue frameLoop }
                    }
                    decoded += 1
                    let half = makeHalfFrame(buffer, timeMs: t, widthPx: widthPx, heightPx: heightPx)

                    // Follow the active faces into this frame.
                    var i = 0
                    while i < active.count {
                        followed += 1
                        let a = active[i]
                        let face = a.face
                        if !(t < face.timeMs), let s = sampleTime(atOrAfter: Int(tc)), !changedSinceUnchanged(face, upToMs: s) {
                            face.hold(atMs: t, unchangedUpToMs: s)
                            i += 1
                            continue
                        }
                        let dy = scrollDy(under: face.rect, fromMs: face.timeMs, toMs: t)
                        if face.follow(to: half, scrollDy: dy) {
                            i += 1
                            continue
                        }
                        tracks.append(makeTrack(a, endMs: t, isLostAtEnd: true))
                        active.remove(at: i)
                        face.unchangedUpToMs = sampleTime(atOrAfter: Int(tc)) ?? Int(t)
                        keepLost(face)
                    }

                    // Revive lost faces whose area changed.
                    if tc < pieceEnd, !lost.isEmpty {
                        let ms = Int(tc)
                        for face in lost {
                            guard let s = sampleTime(atOrAfter: ms), face.unchangedUpToMs < s, changedSinceUnchanged(face, upToMs: s) else { continue }
                            let revived = FollowedFace(continuing: face)
                            if revived.revive(at: half),
                               !active.contains(where: { SD.intersectionOverUnion($0.face.rect, revived.rect) >= 0.3 }) {
                                lost.removeAll { $0 === face }
                                let back = followBack(revived)
                                active.append((revived, back.startMs, back.path, back.isLost))
                            } else {
                                face.unchangedUpToMs = sampleTime(atOrAfter: ms) ?? ms
                            }
                        }
                    }

                    // New sightings.
                    while nextSighting < sightings.count {
                        let sighting = sightings[nextSighting]
                        if tc < Double(sighting.timeMs) { break }
                        nextSighting += 1
                        var matches: [Int] = []
                        for j in active.indices where SD.intersectionOverUnion(active[j].face.rect, sighting.rect) >= 0.3 { matches.append(j) }
                        if matches.isEmpty {
                            guard sighting.timeMs < piece.endMs else { continue }
                            if let face = FollowedFace(rect: sighting.rect, in: half, halfWidth: widthPx / 2, halfHeight: heightPx / 2) {
                                let back = followBack(face)
                                endFacesTakenOver(by: face, before: back.path, at: t, in: half)
                                active.append((face, back.startMs, back.path, back.isLost))
                            } else {
                                let margin = Double(scanner.options.sampleMs)
                                tracks.append(Track(startMs: t - margin, endMs: t + margin, path: [(t, sighting.rect.origin)],
                                                    boxes: [(t, sighting.rect)], isLostAtStart: false, isLostAtEnd: false))
                            }
                        } else {
                            var best = matches[0]
                            for m in matches.dropFirst()
                            where SD.intersectionOverUnion(active[best].face.rect, sighting.rect) < SD.intersectionOverUnion(active[m].face.rect, sighting.rect) {
                                best = m
                            }
                            if sighting.timeMs < piece.endMs {
                                active[best].face.reanchor(to: sighting.rect, in: half)
                            } else {
                                tracks.append(makeTrack(active[best], endMs: t, isLostAtEnd: false))
                                active.remove(at: best)
                            }
                        }
                    }

                    // Face searches that no longer find a followed face end it.
                    while nextSearch < searches.count {
                        let search = searches[nextSearch]
                        if tc < Double(search.timeMs) { break }
                        var gone: [Int] = []
                        for j in active.indices.reversed() where isMissing(active[j].face, in: search) { gone.append(j) }
                        for j in gone where j < active.count {
                            tracks.append(makeTrack(active[j], endMs: t, isLostAtEnd: false))
                            active.remove(at: j)
                        }
                        nextSearch += 1
                    }

                    recent.append(half)
                    while t - recent[0].timeMs > 1200 {
                        recent.removeFirst()
                        if recent.isEmpty { break }
                    }
                    if !(tc < pieceEnd) && active.isEmpty { break restart }

                    // Skip ahead when nothing can change for a while.
                    var jumpMs: Double
                    if nextSighting < sightings.count {
                        let ms = sightings[nextSighting].timeMs
                        if ms < piece.endMs {
                            jumpMs = Double(ms) + -1200
                        } else {
                            if active.isEmpty { continue frameLoop }
                            jumpMs = 0
                            for s in sampledTimesMs.reversed() where s < ms {
                                jumpMs = Double(s)
                                break
                            }
                        }
                    } else {
                        if active.isEmpty { continue frameLoop }
                        jumpMs = followerEnd
                    }
                    var candidates = active.map { $0.face }
                    if t < pieceEnd { candidates.append(contentsOf: lost) }
                    for face in candidates {
                        guard let change = timeline.changes(inAnyOf: grid.tiles(in: face.rect), afterMs: face.unchangedUpToMs, upToMs: Int.max) else { continue }
                        var before = 0.0
                        for s in sampledTimesMs.reversed() where s < change.firstMs {
                            before = Double(s)
                            break
                        }
                        if jumpMs > before { jumpMs = before }
                    }
                    guard jumpMs - t >= 500 else { continue frameLoop }
                    let jumpInt = Int(jumpMs)
                    for a in active {
                        let face = a.face
                        if abs(jumpMs - face.lastFoundMs) > 100 { face.velocity = .zero }
                        face.timeMs = jumpMs
                        face.path.append((jumpMs, CGPoint(x: face.rect.minX + face.pathOffset.dx, y: face.rect.minY + face.pathOffset.dy)))
                        face.unchangedUpToMs = jumpInt
                    }
                    for face in lost where face.unchangedUpToMs < jumpInt { face.unchangedUpToMs = jumpInt }
                    fromMs = jumpMs
                    if followerEnd <= jumpMs { break restart }
                    continue restart
                }
            }
            while !active.isEmpty {
                tracks.append(makeTrack(active[0], endMs: followerEnd, isLostAtEnd: false))
                active.remove(at: 0)
            }
            lock.lock()
            decodedFrames += decoded
            followedFrames += followed
            lock.unlock()
            return tracks
        }

        /// A search of a region that fully contains the face but finds nothing on it counts as a miss; a face
        /// seen once ends after three misses, and any face whose look changed and that stands still ends at once.
        private func isMissing(_ face: FollowedFace, in search: FaceSearch) -> Bool {
            guard search.region.contains(face.rect) else { return false }
            for found in search.faces where SD.intersectionOverUnion(found, face.rect) >= 0.3 { return false }
            face.missesSinceSighting += 1
            if face.isLookChangedSinceSighting, hypot(face.velocity.dx, face.velocity.dy) < 0.03 { return true }
            return face.sightingCount == 1 && face.missesSinceSighting > 2
        }

    }
}
