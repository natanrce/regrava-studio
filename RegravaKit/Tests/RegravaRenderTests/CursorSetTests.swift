import AppKit
import CoreImage
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

struct CursorSetTests {
    @Test func bundlesTheCursorSets() {
        #expect(CursorSets.all.count == 24)
        #expect(CursorSets.all.first?.id == "macos-tahoe")
        let tahoe = CursorSets.set(id: "macos-tahoe")!
        let pointer = tahoe.entry(forType: "pointer", variants: [:])!
        #expect(pointer.hotspot01 == Vec2(0.14, 0.06))
        // A missing type falls back to the pointer; an unknown set to the first.
        #expect(CursorSets.set(id: "custom-2")!.entry(forType: "ibeamstroke", variants: [:])?.type == "pointer")
        #expect(CursorSets.set(id: "nope")?.id == "macos-tahoe")
        #expect(CursorSets.set(id: "custom-7")!.cursors["pointer"]?.count == 13)
        #expect(CursorSets.set(id: "halloween")!.cursors["pointer"]?.count == 8)
        #expect(!CursorSets.pickable(now: Date(timeIntervalSince1970: 1_790_000_000)).contains { $0.id == "halloween" })
    }

    @Test func rastersWithTheBakedShadow() throws {
        let entry = CursorSets.set(id: "macos-tahoe")!.entry(forType: "pointer", variants: [:])!
        let image = try #require(CursorRaster.image(entry.url))
        #expect(min(image.width, image.height) == 512)
        #expect(CursorRaster.shadows(inSVG: try String(contentsOf: entry.url, encoding: .utf8)).first?.dy == 29.26)
        let visible = try #require(CursorRaster.visibleRect01(image))
        // The arrow sits inside its canvas, its shadow left out.
        #expect(visible.y < 0.1 && visible.height > 0.6 && visible.height < 0.95)
        if let dir = ProcessInfo.processInfo.environment["REGRAVA_SNAPSHOT_DIR"] {
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("cursor-tahoe.png"))
        }
    }
}
