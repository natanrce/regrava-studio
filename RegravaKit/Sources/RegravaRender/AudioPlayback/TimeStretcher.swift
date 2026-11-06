import AudioToolbox
import Foundation
import RegravaCore

/// Plays pulled audio at another speed, keeping its pitch (an Apple time-pitch unit).
final class TimeStretcher {
    enum Algorithm {
        /// The time-domain unit.
        case timeDomain
        /// The newer spectral unit, used on macOS 14.
        case spectral

        static var current: Algorithm {
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 14 ? .spectral : .timeDomain
        }
    }

    /// The time-domain unit reports no latency; this is what it delays by.
    static let measuredTimeDomainLatencyFrames = 672
    static let maximumFramesPerSlice = 4096

    typealias Pull = (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Void

    private final class Feeder {
        let pull: Pull
        init(pull: @escaping Pull) { self.pull = pull }
    }

    private(set) var speed: Double
    /// Frames between pulled input and rendered output.
    private(set) var latencyFrames: Int
    private let unit: AudioUnit
    private let feeder: Feeder
    private var sampleTime: Double = 0
    private let outputList: UnsafeMutableAudioBufferListPointer
    private var discard: [Float]

    init(speed: Double, algorithm: Algorithm, pull: @escaping Pull) throws {
        self.speed = speed
        feeder = Feeder(pull: pull)
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter,
            componentSubType: algorithm == .spectral ? kAudioUnitSubType_NewTimePitch : kAudioUnitSubType_AUiPodTimeOther,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { throw MixError.invalidSegment("no time-pitch unit") }
        var instance: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &instance), "open the time-pitch unit")
        guard let instance else { throw MixError.invalidSegment("no time-pitch unit") }
        unit = instance
        outputList = AudioBufferList.allocate(maximumBuffers: 2)
        discard = [Float](repeating: 0, count: 2 * Self.maximumFramesPerSlice)
        latencyFrames = 0
        var format = MixPlaybackFormat.streamDescription
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, size), "set the input format")
        try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, size), "set the output format")
        var maxFrames = UInt32(Self.maximumFramesPerSlice)
        try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4), "set the slice size")
        var callback = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frames, data in
            guard let data else { return noErr }
            let feeder = Unmanaged<Feeder>.fromOpaque(refCon).takeUnretainedValue()
            let buffers = UnsafeMutableAudioBufferListPointer(data)
            guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            feeder.pull(left, right, Int(frames))
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(feeder).toOpaque())
        try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set the input")
        try Self.check(AudioUnitInitialize(unit), "start the time-pitch unit")
        try Self.check(AudioUnitSetParameter(unit, kTimePitchParam_Rate, kAudioUnitScope_Global, 0, Float(speed), 0), "set the speed")
        if algorithm == .timeDomain {
            latencyFrames = Self.measuredTimeDomainLatencyFrames
        } else {
            var latency: Float64 = 0
            var latencySize = UInt32(MemoryLayout<Float64>.size)
            AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &latencySize)
            latencyFrames = Int(MixFormat.frames(seconds: latency))
        }
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        outputList.unsafeMutablePointer.deallocate()
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw MixError.invalidSegment("could not \(what) (\(status))") }
    }

    func setSpeed(_ speed: Double) {
        guard speed != self.speed else { return }
        self.speed = speed
        AudioUnitSetParameter(unit, kTimePitchParam_Rate, kAudioUnitScope_Global, 0, Float(speed), 0)
    }

    /// Renders `count` frames into `left` and `right`.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        var done = 0
        while done < count {
            let n = min(count - done, Self.maximumFramesPerSlice)
            renderSlice(left: left + done, right: right + done, count: n)
            done += n
        }
    }

    /// Renders and drops `count` frames.
    func skip(_ count: Int) {
        guard count > 0 else { return }
        var left = count
        discard.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            while left > 0 {
                let n = min(left, Self.maximumFramesPerSlice)
                renderSlice(left: base, right: base + Self.maximumFramesPerSlice, count: n)
                left -= n
            }
        }
    }

    private func renderSlice(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        let bytes = UInt32(count * MemoryLayout<Float>.size)
        outputList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(left))
        outputList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(right))
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid
        let status = AudioUnitRender(unit, &flags, &timestamp, 0, UInt32(count), outputList.unsafeMutablePointer)
        if status != noErr {
            left.update(repeating: 0, count: count)
            right.update(repeating: 0, count: count)
        }
        sampleTime += Double(count)
    }
}
