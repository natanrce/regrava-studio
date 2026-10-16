import Foundation

/// Which cursor image is drawn when.
public enum CursorTypes {
    /// Known recorded cursor ids.
    static let recordedIDs = "arrow.iBeam.crosshair.closedHand.openHand.pointingHand.resizeLeft.resizeRight.resizeLeftRight.resizeUp.resizeDown.resizeUpDown.disappearingItem.iBeamCursorForVerticalLayout.operationNotAllowed.dragLink.dragCopy.contextualMenu.windowResizeNorthEast.windowResizeNorthWestSouthEast.zoomIn.windowResizeNorthWest.windowResizeSouthEast.windowResizeEastWest.windowResizeNorth.windowResizeEast.windowResizeNorthSouth.windowResizeNorthEastSouthWest.windowResizeWest.windowResizeSouth.windowResizeSouthWest.bottomRightResize.bottomLeftResize.topRightResize.topLeftResize.help.notAllowed.makeAlias.copy.zoomOut.busyButClickable"

    /// Cursor image names of a cursor set.
    static let assetNames = "beachball.busybutclickable.cell.closedhand.contextualmenu.copy.cross.crosshair.help.makealias.move.notallowed.openhand.pointer.pointinghand.poof.resizedown.resizeeast.resizeeastwest.resizeleftright.resizeleft.resizenorth.resizenortheastsouthwest.resizenortheast.resizenorthsouth.resizenorthwestsoutheast.resizenorthwest.resizeright.resizesouth.resizesoutheast.resizesouthwest.resizeupdown.resizeup.resizewest.screenshotselection.screenshotwindow.zoomout.zoomin.ibeamstroke.ibeamverticalstroke.ibeamvertical.ibeam"

    /// Recorded id → image name.
    static let recordedToAsset: [String: String] = [
        "arrow": "pointer", "iBeam": "ibeamstroke", "crosshair": "cross", "closedHand": "closedhand",
        "openHand": "openhand", "pointingHand": "pointinghand", "resizeLeft": "resizeleft",
        "resizeRight": "resizeright", "resizeLeftRight": "resizeleftright", "resizeUp": "resizeup",
        "resizeDown": "resizedown", "resizeUpDown": "resizeupdown", "disappearingItem": "poof",
        "iBeamCursorForVerticalLayout": "ibeamvertical", "operationNotAllowed": "notallowed",
        "dragLink": "makealias", "dragCopy": "copy", "contextualMenu": "contextualmenu",
        "windowResizeNorthEast": "resizenortheast", "windowResizeNorthWestSouthEast": "resizenorthwestsoutheast",
        "zoomIn": "zoomin", "windowResizeNorthWest": "resizenorthwest", "windowResizeSouthEast": "resizesoutheast",
        "windowResizeEastWest": "resizeeastwest", "windowResizeNorth": "resizenorth", "windowResizeEast": "resizeeast",
        "windowResizeNorthSouth": "resizenorthsouth", "windowResizeNorthEastSouthWest": "resizenortheastsouthwest",
        "windowResizeWest": "resizewest", "windowResizeSouth": "resizesouth", "windowResizeSouthWest": "resizesouthwest",
        "bottomRightResize": "resizesoutheast", "bottomLeftResize": "resizesouthwest", "topRightResize": "resizenortheast",
        "topLeftResize": "resizenorthwest", "help": "help", "notAllowed": "notallowed", "makeAlias": "makealias",
        "copy": "copy", "zoomOut": "zoomout", "busyButClickable": "busybutclickable",
    ]

    public static let defaultName = "pointer"

    public static func isCustom(_ id: String) -> Bool { id.hasPrefix("custom-") }

    /// Image name for a recorded cursor id. membership is a substring test on the joined
    /// lists; unknown ids fall back to the pointer.
    public static func assetName(for recordedID: String?) -> String {
        let id = recordedID ?? "arrow"
        if isCustom(id) { return id }
        if recordedIDs.contains(id) { return recordedToAsset[id] ?? defaultName }
        if assetNames.contains(id) { return id }
        return defaultName
    }

    /// "Optimize cursor changes": keeps only cursor changes that matter. The cursor in effect
    /// when a press starts, drags that change the cursor, releases, and a return to the arrow
    /// when the cursor moves on more than 250 ms after a release.
    public static func optimized(_ events: [MouseEvent]) -> [MouseEvent] {
        var result: [MouseEvent] = []
        var runStart: MouseEvent?
        for event in events {
            if runStart == nil { runStart = event }
            if runStart!.cursorID != event.cursorID { runStart = event }
            let last = result.last
            if event.kind == .drag {
                guard let last else {
                    result.append(event)
                    continue
                }
                if last.cursorID != event.cursorID { result.append(event) }
            }
            if event.kind == .move, let last, last.kind == .up, last.cursorID != event.cursorID, event.timeMs - last.timeMs > 250 {
                var arrow = event
                arrow.cursorID = "arrow"
                result.append(arrow)
            }
            if event.kind == .down, let start = runStart {
                result.append(start)
                runStart = nil
            }
            if event.kind == .up { result.append(event) }
        }
        return result
    }

    /// Events that decide the cursor image.
    public static func typeEvents(_ events: [MouseEvent], config: CursorConfig) -> [MouseEvent] {
        config.optimizeOriginalTypes ? optimized(events) : events
    }

    /// Times where the drawn image changes, used as planner sync points.
    public static func imageChangeTimes(_ typeEvents: [MouseEvent], config: CursorConfig) -> [Double] {
        guard !config.alwaysUseDefault else { return [] }
        var times: [Double] = []
        var previous: String?
        for event in typeEvents {
            let name = assetName(for: event.cursorID)
            if let previous, previous != name { times.append(event.timeMs) }
            previous = name
        }
        return times
    }

    /// Image name in effect at `t`.
    public static func assetName(at t: Double, typeEvents: [MouseEvent], config: CursorConfig) -> String {
        guard !config.alwaysUseDefault else { return defaultName }
        let index = floorSearch(count: typeEvents.count, value: t) { typeEvents[$0].timeMs }
        return assetName(for: index.map { typeEvents[$0].cursorID } ?? nil)
    }

    /// Whether the cursor is drawn pressed at `t`. With smooth movement the drawn cursor runs
    /// slightly ahead, so a press or release within the next 500 ms already counts. `clicks`
    /// are the presses and releases of `events`.
    public static func isPressed(at t: Double, events: [MouseEvent], clicks: [MouseEvent], smoothed: Bool) -> Bool {
        var effective: MouseEvent?
        if smoothed {
            if let i = ceilSearch(count: clicks.count, value: t, key: { clicks[$0].timeMs }), clicks[i].timeMs - t <= 500 {
                effective = clicks[i]
            }
        }
        if effective == nil {
            if let i = floorSearch(count: events.count, value: t, key: { events[$0].timeMs }) {
                effective = events[i]
            } else {
                effective = events.first
            }
        }
        return effective?.kind == .down || effective?.kind == .drag
    }
}
