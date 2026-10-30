import Foundation
import ScreenCaptureKit
import Testing
@testable import RegravaCapture

struct StreamStopErrorTests {
    @Test func stopWithoutAnError() {
        let plain = CaptureError.streamStop(nil, isLowDiskSpace: false)
        #expect(plain.localizedDescription == "ScreenCaptureKit stopped without reporting any error information.")
        guard case let .streamStopped(_, internalMessage, userMessage)? = plain as? CaptureError else { Issue.record("not a stream stop"); return }
        #expect(internalMessage == "internalError: ScreenCaptureKit stopped without reporting any error information.")
        #expect(userMessage == nil)

        let lowDisk = CaptureError.streamStop(nil, isLowDiskSpace: true)
        #expect(lowDisk.localizedDescription == "Recording stopped due to low disk space.")
        guard case let .streamStopped(message, _, _)? = lowDisk as? CaptureError else { Issue.record("not a stream stop"); return }
        #expect(message == "nil error from ScreenCaptureKit")
    }

    @Test func systemStopBlamesLowDiskSpaceOnlyWhenThereIsNone() {
        let stopped = SCStreamError(.systemStoppedStream)
        #expect(CaptureError.streamStop(stopped, isLowDiskSpace: true).localizedDescription == "Recording stopped due to low disk space.")
        #expect((CaptureError.streamStop(stopped, isLowDiskSpace: false) as NSError).code == SCStreamError.Code.systemStoppedStream.rawValue)
        let other = SCStreamError(.userStopped)
        #expect((CaptureError.streamStop(other, isLowDiskSpace: true) as NSError).code == SCStreamError.Code.userStopped.rawValue)
    }

    /// Low means nothing left for opportunistic use, as the volume reports it.
    @Test func lowDiskSpaceFollowsTheOpportunisticCapacity() throws {
        let url = FileManager.default.temporaryDirectory
        let available = try url.resourceValues(forKeys: [.volumeAvailableCapacityForOpportunisticUsageKey]).volumeAvailableCapacityForOpportunisticUsage
        #expect(CaptureError.isVolumeLowOnDiskSpace(url) == (available == 0))
        #expect(!CaptureError.isVolumeLowOnDiskSpace(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")))
    }
}
