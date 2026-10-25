import AVFoundation
import AppKit
import Foundation
import Testing
import RegravaCore
@testable import RegravaRender

struct SensitiveDataScannerTests {
    /// Two seconds of a page with an email on it: the scan finds it where it is drawn.
    @Test func findsAnEmailOnScreen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let width = 1280, height = 720
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer!), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!),
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Contact: john.doe@example.com" as NSString).draw(at: NSPoint(x: 200, y: 400), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
        NSGraphicsContext.current = nil
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        for i in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        let detections = try await SensitiveDataScanner.scan(video: url, phrases: [], detectFaces: false) { _, _ in }
        let email = try #require(detections.first { $0.kind == .email })
        #expect(email.text.contains("john.doe@example.com"))
        let box = try #require(email.keyframes.first)
        // Drawn at x 200…, y 720 − 400 − text height (top-left origin).
        #expect(box.x > 250 && box.x < 400)
        #expect(box.y > 260 && box.y < 320)
    }
}
