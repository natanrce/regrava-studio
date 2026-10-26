import CoreGraphics
import CryptoKit
import Foundation

// The evidence codec. Every integer is written little endian with
// the host's `withUnsafeBytes`; counts are Int64; `[Int]` elements are Int32 (trap outside Int32);
// CGRect is a null flag byte followed (when not null) by minX, minY, width, height as Double;
// strings are UTF-8 bytes written like `[UInt8]` (Int64 count + bytes).

extension SD {
    /// fnv1a64: FNV-1a 64 over the bytes.
    static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return hash
    }

    /// shortHash: the first 10 bytes of SHA256(utf8) as lowercase hex ("%02x"), joined.
    static func shortHash(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: BinaryWriter

    // The stored property's name; the writer holds a single Data that every write appends to.
    struct BinaryWriter {
        var data = Data()

        mutating func write<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        mutating func write(_ value: Double) {
            write(value.bitPattern)
        }

        mutating func write(_ value: Bool) {
            write(UInt8(value ? 1 : 0))
        }

        mutating func write(_ bytes: [UInt8]) {
            write(Int64(bytes.count))
            data.append(contentsOf: bytes)
        }

        /// Count, then each Int as Int32 (traps when it does not fit, like `Int32(_:)`).
        mutating func write(_ values: [Int]) {
            write(Int64(values.count))
            for value in values {
                write(Int32(value))
            }
        }

        mutating func write(_ string: String) {
            write(Array(string.utf8))
        }

        mutating func write(_ rect: CGRect) {
            write(rect.isNull)
            if !rect.isNull {
                write(Double(rect.minX))
                write(Double(rect.minY))
                write(Double(rect.width))
                write(Double(rect.height))
            }
        }

        mutating func write(_ findings: [Finding]) {
            write(Int64(findings.count))
            for finding in findings {
                write(finding.kind)
                write(finding.text)
                write(finding.key)
                write(finding.rect)
            }
        }

        mutating func write(_ observation: Observation) {
            write(Int64(observation.timeMs))
            write(observation.region)
            write(observation.faceRegion)
            write(Int64(observation.lines.count))
            for line in observation.lines {
                write(line.text)
                write(line.key)
                write(line.rect)
            }
            write(observation.findings)
            write(Int64(observation.firstTile))
            write(observation.tileSignatures)
        }
    }

    // MARK: BinaryReader

    // The stored properties' names; the reader holds the bytes as [UInt8] and a read offset.
    struct BinaryReader {
        var bytes: [UInt8]
        var offset = 0

        /// init(_:): copies the Data into an [UInt8].
        init(_ data: Data) {
            bytes = [UInt8](data)
        }

        private static var truncated: EvidenceDecodingError { EvidenceDecodingError(reason: "truncated") }
        private static var badCount: EvidenceDecodingError { EvidenceDecodingError(reason: "bad count") }

        /// take(_:)
        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, offset + count <= bytes.count else { throw Self.truncated }
            let slice = bytes[offset..<(offset + count)]
            offset += count
            return slice
        }

        /// littleEndian(_:): a fixed-width integer, little endian.
        mutating func littleEndian<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= bytes.count else { throw Self.truncated }
            var value: T = 0
            for index in 0..<size {
                value |= T(truncatingIfNeeded: bytes[offset + index]) << (8 * index)
            }
            offset += size
            return value
        }

        /// bool(): any non-zero byte is true.
        mutating func bool() throws -> Bool {
            guard offset + 1 <= bytes.count else { throw Self.truncated }
            let byte = bytes[offset]
            offset += 1
            return byte != 0
        }

        mutating func double() throws -> Double {
            Double(bitPattern: try littleEndian(UInt64.self))
        }

        /// The count check of uint64s/int16s/ints: 0 ≤ count ≤ remaining BYTES (not elements).
        private mutating func boundedCount() throws -> Int {
            let count = Int(try littleEndian(Int64.self))
            guard count >= 0, count <= bytes.count - offset else { throw Self.badCount }
            return count
        }

        /// uint64s()
        mutating func uint64s() throws -> [UInt64] {
            let count = try boundedCount()
            var values: [UInt64] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try littleEndian(UInt64.self)) }
            return values
        }

        /// int16s()
        mutating func int16s() throws -> [Int16] {
            let count = try boundedCount()
            var values: [Int16] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try littleEndian(Int16.self)) }
            return values
        }

        /// ints(): Int32 elements.
        mutating func ints() throws -> [Int] {
            let count = try boundedCount()
            var values: [Int] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(Int(try littleEndian(Int32.self))) }
            return values
        }

        /// Int64 length, take, String(bytes:encoding: .utf8) or "not UTF-8".
        mutating func string() throws -> String {
            let count = Int(try littleEndian(Int64.self))
            let slice = try take(count)
            guard let string = String(bytes: slice, encoding: .utf8) else {
                throw EvidenceDecodingError(reason: "not UTF-8")
            }
            return string
        }

        /// Null flag, then 4 Doubles, or CGRect.null.
        mutating func rect() throws -> CGRect {
            if try bool() { return .null }
            let x = try double()
            let y = try double()
            let width = try double()
            let height = try double()
            return CGRect(x: x, y: y, width: width, height: height)
        }

        /// finding()
        mutating func finding() throws -> Finding {
            let kind = try string()
            let text = try string()
            let key = try string()
            let rect = try rect()
            return Finding(kind: kind, text: text, key: key, rect: rect)
        }

        /// findings(): no bound check on the count (a negative count traps).
        mutating func findings() throws -> [Finding] {
            let count = Int(try littleEndian(Int64.self))
            var findings: [Finding] = []
            if count != 0 { findings.reserveCapacity(count) }
            for _ in 0..<count { findings.append(try finding()) }
            return findings
        }

        /// read()
        mutating func read() throws -> Observation {
            let timeMs = Int(try littleEndian(Int64.self))
            let region = try rect()
            let faceRegion = try rect()
            let lineCount = Int(try littleEndian(Int64.self))
            var lines: [RecognizedLine] = []
            for _ in 0..<lineCount {
                let text = try string()
                let key = try string()
                let rect = try rect()
                lines.append(RecognizedLine(text: text, key: key, rect: rect))
            }
            let findings = try findings()
            let firstTile = Int(try littleEndian(Int64.self))
            let signatureCount = Int(try littleEndian(Int64.self))
            let signatures = Array(try take(signatureCount))
            return Observation(timeMs: timeMs, region: region, faceRegion: faceRegion, lines: lines, findings: findings,
                               firstTile: firstTile, tileSignatures: signatures)
        }
    }

    // MARK: EvidenceFile

    /// `enum EvidenceFile`: "SSDE", Int64 version, Int64 payload length, UInt64 fnv1a64(payload), LZFSE(payload).
    enum EvidenceFile {
        /// magic
        static let magic: [UInt8] = Array("SSDE".utf8)

        /// encode(_:version:)
        static func encode(_ payload: Data, version: Int) throws -> Data {
            var header = BinaryWriter()
            header.write(Int64(version))
            header.write(Int64(payload.count))
            header.write(fnv1a64(payload))
            var file = Data(magic)
            file += header.data
            let compressed = try (payload as NSData).compressed(using: .lzfse) as Data
            file += compressed
            return file
        }

        /// decode(_:version:)
        static func decode(_ file: Data, version: Int) throws -> Data {
            guard file.count > magic.count + 24, Array(file.prefix(magic.count)) == magic else {
                throw EvidenceDecodingError(reason: "not evidence")
            }
            var header = BinaryReader(Data(file.dropFirst(magic.count).prefix(24)))
            guard Int(try header.littleEndian(Int64.self)) == version else {
                throw EvidenceDecodingError(reason: "another version")
            }
            let length = Int(try header.littleEndian(Int64.self))
            let checksum = try header.littleEndian(UInt64.self)
            let compressed = Data(file.dropFirst(magic.count + 24))
            let payload = try (compressed as NSData).decompressed(using: .lzfse) as Data
            guard payload.count == length, fnv1a64(payload) == checksum else {
                throw EvidenceDecodingError(reason: "checksum")
            }
            return payload
        }
    }
}

// MARK: Chunk payloads

extension SD.ChunkEvidence {
    /// encoded()
    func encoded() -> Data {
        var writer = SD.BinaryWriter()
        writer.write(Int64(chunkIndex))
        writer.write(Int64(changeSamples.count))
        for sample in changeSamples {
            writer.write(Int64(sample.timeMs))
            writer.write(sample.isEverything)
            writer.write(Int64(sample.changedTiles.count))
            for word in sample.changedTiles { writer.write(word) }
            writer.write(sample.changedTileList)
            writer.write(sample.signatures != nil)
            if let signatures = sample.signatures { writer.write(signatures) }
            writer.write(Int64(sample.stripeShiftsPx.count))
            for shift in sample.stripeShiftsPx { writer.write(shift) }
        }
        writer.write(sampledTimesMs)
        // The count is reads.count; the loop zips reads with readHasPhotos.
        writer.write(Int64(reads.count))
        for (read, hasPhotos) in zip(reads, readHasPhotos) {
            writer.write(read)
            writer.write(hasPhotos)
        }
        return writer.data
    }

    /// init(decoding:)
    init(decoding data: Data) throws {
        var reader = SD.BinaryReader(data)
        let chunkIndex = Int(try reader.littleEndian(Int64.self))
        let sampleCount = Int(try reader.littleEndian(Int64.self))
        var samples: [SD.ChangeSample] = []
        if sampleCount != 0 { samples.reserveCapacity(sampleCount) }
        for _ in 0..<sampleCount {
            let timeMs = Int(try reader.littleEndian(Int64.self))
            let isEverything = try reader.bool()
            let changedTiles = try reader.uint64s()
            let changedTileList = try reader.ints()
            var signatures: [UInt8]?
            if try reader.bool() {
                let count = Int(try reader.littleEndian(Int64.self))
                signatures = Array(try reader.take(count))
            }
            let shifts = try reader.int16s()
            samples.append(SD.ChangeSample(timeMs: timeMs, isEverything: isEverything, changedTiles: changedTiles,
                                           changedTileList: changedTileList, signatures: signatures, stripeShiftsPx: shifts))
        }
        let sampledTimesMs = try reader.ints()
        let readCount = Int(try reader.littleEndian(Int64.self))
        var reads: [SD.Observation] = []
        var readHasPhotos: [Bool] = []
        for _ in 0..<readCount {
            reads.append(try reader.read())
            readHasPhotos.append(try reader.bool())
        }
        guard reader.offset == reader.bytes.count else { throw SD.EvidenceDecodingError(reason: "trailing bytes") }
        self.init(chunkIndex: chunkIndex, changeSamples: samples, sampledTimesMs: sampledTimesMs, reads: reads,
                  readHasPhotos: readHasPhotos)
    }
}

extension SD.ChunkFaces {
    /// encoded()
    func encoded() -> Data {
        var writer = SD.BinaryWriter()
        writer.write(Int64(facesByRead.count))
        for faces in facesByRead { writer.write(faces) }
        return writer.data
    }

    /// init(decoding:)
    init(decoding data: Data) throws {
        var reader = SD.BinaryReader(data)
        let count = Int(try reader.littleEndian(Int64.self))
        var facesByRead: [[SD.Finding]] = []
        for _ in 0..<count { facesByRead.append(try reader.findings()) }
        guard reader.offset == reader.bytes.count else { throw SD.EvidenceDecodingError(reason: "trailing bytes") }
        self.init(facesByRead: facesByRead)
    }
}

extension SD.ChunkPhrase {
    /// encoded(): count, then the entries sorted by key ascending (key Int64, findings).
    func encoded() -> Data {
        var writer = SD.BinaryWriter()
        writer.write(Int64(findingsByRead.count))
        for (key, value) in findingsByRead.sorted(by: { $0.key < $1.key }) {
            writer.write(Int64(key))
            writer.write(value)
        }
        return writer.data
    }

    /// init(decoding:)
    init(decoding data: Data) throws {
        var reader = SD.BinaryReader(data)
        let count = Int(try reader.littleEndian(Int64.self))
        var findingsByRead: [Int: [SD.Finding]] = [:]
        for _ in 0..<count {
            let key = Int(try reader.littleEndian(Int64.self))
            findingsByRead[key] = try reader.findings()
        }
        guard reader.offset == reader.bytes.count else { throw SD.EvidenceDecodingError(reason: "trailing bytes") }
        self.init(findingsByRead: findingsByRead)
    }
}

extension SD.FaceTrack {
    /// FaceFollower.Track.write(into:)
    func write(into writer: inout SD.BinaryWriter) {
        writer.write(startMs)
        writer.write(endMs)
        writer.write(Int64(path.count))
        for point in path {
            writer.write(point.timeMs)
            writer.write(Double(point.point.x))
            writer.write(Double(point.point.y))
        }
        writer.write(Int64(boxes.count))
        for box in boxes {
            writer.write(box.timeMs)
            writer.write(box.rect)
        }
        writer.write(isLostAtStart)
        writer.write(isLostAtEnd)
    }

    /// FaceFollower.Track.init(reading:)
    init(reading reader: inout SD.BinaryReader) throws {
        let startMs = try reader.double()
        let endMs = try reader.double()
        let pathCount = Int(try reader.littleEndian(Int64.self))
        var path: [(timeMs: Double, point: CGPoint)] = []
        for _ in 0..<pathCount {
            let timeMs = try reader.double()
            let x = try reader.double()
            let y = try reader.double()
            path.append((timeMs: timeMs, point: CGPoint(x: x, y: y)))
        }
        let boxCount = Int(try reader.littleEndian(Int64.self))
        var boxes: [(timeMs: Double, rect: CGRect)] = []
        for _ in 0..<boxCount {
            let timeMs = try reader.double()
            let rect = try reader.rect()
            boxes.append((timeMs: timeMs, rect: rect))
        }
        let isLostAtStart = try reader.bool()
        let isLostAtEnd = try reader.bool()
        self.init(startMs: startMs, endMs: endMs, path: path, boxes: boxes, isLostAtStart: isLostAtStart, isLostAtEnd: isLostAtEnd)
    }
}
