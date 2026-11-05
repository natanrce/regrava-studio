import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

/// A fading cursor trailing over a debanded recording, with the camera and a caption on top,
/// must leave the background as it is without the trail.
struct TrailInputsTests {
    static let projectJSON = #"""
{"animation":{"motionBlurAmount":1,"mouseSpring":{"clampOvershoot":true,"damping":12,"mass":1.5,"precision":0.002,"stiffness":125},"screenSpring":{"clampOvershoot":true,"damping":12,"mass":1.5,"precision":0.002,"stiffness":125},"startsZoomEarly":false},"audio":{"backgroundAudioVolume":0.03,"clickSoundEffectVolume":0.25,"microphoneAudioPreset":"channel-fix","muteBackgroundAudio":false,"muteExternalDeviceAudio":false,"muteMicrophone":false,"muteSystemAudio":false,"volume":1},"autoZoom":{"endMarginMs":800,"holdMs":2500,"ignoreClicksInLastMs":1000,"isEnabled":false,"leadMs":300,"mergeGapMs":2500,"scale":2},"camera":{"aspectRatio":1,"background":{"blurAmount01":0,"edgeFalloff01":0.2,"edgeInsetPx":0},"delayAdjustmentMs":0,"enableFaceTracking":false,"grain":0,"hide":false,"lutIntensity":1,"mirror":false,"sharpen01":0},"cameraLayouts":[],"captions":{"backgroundColor":"#000000","color":"#ffffff","enableShortcuts":false,"enableTranscript":true,"font":"sans-serif","hiddenShortcuts":{},"lineGrowth":"left-anchored","position01":{"x":0.5,"y":1},"shortcutsSizeRatio":0.1,"showShortcutsWithSingleLetters":false,"showSoundLabels":false,"sizeRatio":0.05,"wordEntrance":"appear","wordsReveal":"line-by-line"},"crop":{"rect01":{"height":1,"width":1,"x":0,"y":0}},"cursor":{"alwaysUseDefault":false,"baseRotation":0,"followRecordedPositionOnHover":true,"hide":false,"optimizeOriginalTypes":true,"removeShakeThreshold":500,"rotateOnXMovementRatio":0.5,"rotationMode":"velocity","set":{"id":"macos-tahoe","variants":{}},"size":48,"stopMovementInLastPartMs":0},"defaultLayout":{"cameraOverlay":{"aspectRatio":1,"paddingRatio01":0.5,"position01":{"x":1,"y":1},"sizeRatio01":0.5,"zoomedScale":0.8},"cutoutCamera":{"positionX01":1,"sizeRatio01":0.5,"zoomedScale":0.8},"splitScreen":{"direction":"auto","enablePadding":false,"flip":false},"type":"camera-overlay"},"device":{"enableMockup":true},"formatVersion":1,"keystrokes":[],"markersMs":[],"masks":[],"mouseEvents":[{"button":0,"cursorID":"arrow","kind":"move","position":{"x":1500,"y":1000},"timeMs":0}],"processing":{"autoMaskFaces":false,"autoMaskSensitiveData":false,"improveRecordingQuality01":0.5,"sensitiveDataCustomPhrases":[],"sensitiveDataExpandPx":8},"recording":{"audioSources":["microphone"],"cameraFileName":"camera.mov","cameraSize":{"height":1080,"width":1920},"createdAt":"2026-11-04T23:33:31Z","cursors":[],"durationMs":4000,"flags":[],"fps":60,"mode":"display","pointPixelScale":2,"sessionStartsMs":[],"videoFileName":"recording.mov","videoSize":{"height":1964,"width":3024}},"resolvedTypingSuggestionsMs":[],"slices":[],"style":{"avoidEmptyZoomArea":false,"background":{"blur":0,"color":{"a":1,"b":0.9019607843137255,"g":0.4627450980392157,"r":0.2784313725490196},"gradient":{"end":{"x":1,"y":1},"start":{"x":0,"y":0},"stops":[{"at":0,"color":{"a":1,"b":0.9019607843137255,"g":0.4627450980392157,"r":0.2784313725490196}},{"at":1,"color":{"a":1,"b":0.9137254901960784,"g":0.32941176470588235,"r":0.5568627450980392}}]},"kind":"system","systemName":"macOS/san-francisco-dark.jpg"},"cameraBorderRadiusRatio":0.15,"cornerRadius":16,"inset":{"alpha":0.25,"color":{"a":1,"b":0.5333333333333333,"g":0.5333333333333333,"r":0.5333333333333333},"origin01":{"x":0.5,"y":0.5},"size":0},"paddingRatio":0.1,"shadow":{"angle":45,"blur":20,"distance":25,"intensity":0.3,"isDirectional":true}},"zooms":[]}
"""#

    private func buffer(_ width: Int, _ height: Int, seed: Double) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        // Bright, varied content up to the edges: a wrong read past them shows on the background.
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .transformed(by: CGAffineTransform(translationX: seed, y: seed))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        CanvasCompositor.context.render(noise, to: buffer!)
        return buffer!
    }

    /// Mean green of the background left of the screen, in output pixels.
    private func leftMargin(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        var sum = 0, count = 0
        for y in stride(from: 600, to: 1600, by: 10) {
            for x in 0..<100 { sum += Int(base[y * row + x * 4 + 1]); count += 1 }
        }
        return Double(sum) / Double(count)
    }

    @Test func cursorTrailLeavesTheBackgroundAlone() throws {
        let project = try JSONDecoder().decode(Project.self, from: Data(Self.projectJSON.utf8))
        let words = ["ser", "transcrito", "corretamente?"].enumerated().map {
            TranscriptWord(index: $0.offset, startMs: 500 + Double($0.offset) * 300, endMs: 700 + Double($0.offset) * 300, text: $0.element)
        }
        let track = CameraTrack(project: project, fps: 60)
        let compositor = FrameCompositor(project: project, layout: track.layout, cursors: CursorLibrary.arrowOnly(), transcript: words, fps: 60)
        let source = CIImage(cvPixelBuffer: buffer(3024, 1964, seed: 0))
        let camera = CIImage(cvPixelBuffer: buffer(1920, 1080, seed: 50))
        let size = CGSize(width: 3130, height: 2160)
        let output = buffer(3130, 2160, seed: 0)
        func margin(_ frame: CameraFrame) -> Double {
            var image = compositor.compose(source: source, camera: camera, frame: frame, quality: .export)
            image = image.transformed(by: CGAffineTransform(scaleX: size.width / track.layout.canvas.width, y: size.height / track.layout.canvas.height))
            CanvasCompositor.context.render(image.cropped(to: CGRect(origin: .zero, size: size)), to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: CanvasCompositor.sRGB)
            return leftMargin(output)
        }
        var base = track.frame(at: 1500)
        base.cursor = Vec2(1500, 1000)
        base.cursorOpacity = 0.48
        base.cursorFadeBlurRadius = 3
        base.previousCursor = base.cursor
        let reference = margin(base)
        let videoToCanvas = base.screenRect.width / project.recording.videoSize.width
        for samples in 2...16 {
            var frame = base
            // Export trails take a sample every 4 canvas pixels of travel.
            frame.previousCursor = Vec2(1500 + (Double(samples) * 4 - 2) / videoToCanvas, 1000)
            #expect(abs(margin(frame) - reference) < 0.5, "trail of \(samples) samples")
        }
    }
}
