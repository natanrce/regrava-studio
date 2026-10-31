import Foundation

/// A preset package's `meta.json` (`<name>.<extension>/meta.json`): superjson's `{"json": {version,
/// app: {version}, projectConfig}}`, the config in the project schema (cursor, captions, audio,
/// camera, animations, processing, zooms, defaultLayout, device, output, styles). Reads both preset
/// package extensions alike.
public enum PresetFile {
    public static let fileName = "meta.json"
    public static let assetsFolderName = "assets"
    /// The project format the config is written in.
    public static let formatVersion = "4.0.0"

    public enum Failure: LocalizedError {
        case invalidData
        case invalidVersion(String)

        public var errorDescription: String? {
            switch self {
            case .invalidData: return "Preset data is invalid"
            case .invalidVersion(let version): return "preset meta.json has an invalid version: \"\(version)\""
            }
        }
    }

    // MARK: Writing

    public static func encode(_ config: PresetConfig, appVersion: String) throws -> Data {
        let root: [String: Any] = ["json": [
            "version": formatVersion,
            "app": ["version": appVersion],
            "projectConfig": projectConfig(config),
        ]]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func projectConfig(_ config: PresetConfig) -> [String: Any] {
        let style = config.style, cursor = config.cursor, animation = config.animation, audio = config.audio
        let camera = config.camera ?? CameraConfig()
        let layout = config.defaultLayout ?? DefaultCameraLayout()
        let processing = config.processing ?? ProcessingConfig()
        let device = config.device ?? DeviceConfig()
        func vec(_ v: Vec2) -> [String: Any] { ["x": v.x, "y": v.y] }
        func spring(_ s: SpringConfig) -> [String: Any] {
            ["stiffness": s.stiffness, "damping": s.damping, "mass": s.mass, "clamp": s.clampOvershoot, "precision": s.precision]
        }
        let stops = style.background.gradientStops
        var processingJSON: [String: Any] = ["improveRecordingQuality01": processing.improveRecordingQuality01]
        // These are written only when they differ from their defaults.
        if processing.autoMaskSensitiveData { processingJSON["autoMaskSensitiveData"] = true }
        if processing.sensitiveDataExpandPx != 8 { processingJSON["sensitiveDataExpandPx"] = processing.sensitiveDataExpandPx }
        if !processing.sensitiveDataCustomPhrases.isEmpty { processingJSON["sensitiveDataCustomPhrases"] = processing.sensitiveDataCustomPhrases }
        if processing.autoMaskFaces { processingJSON["autoMaskFaces"] = true }
        let captions = config.captions ?? CaptionsConfig()
        return [
            "cursor": [
                "hide": cursor.hide,
                "size": cursor.size,
                "stopMovementInLastPartMs": cursor.stopMovementInLastPartMs,
                "set": ["id": cursor.set.id, "variants": cursor.set.variants],
                "rotationMode": "velocity",
                "rotateOnXMovementRatio": 0.5,
                "baseRotation": cursor.baseRotation,
                "useDefaultIfAppHasLowResolution": true,
                "alwaysUseDefault": cursor.alwaysUseDefault,
                "hideNotMovingAfterMs": cursor.hideNotMovingAfterMs ?? NSNull(),
                "loopPositionBeforeEndMs": cursor.loopPositionBeforeEndMs ?? NSNull(),
                "removeShakeTreshold": cursor.removeShakeThreshold,
                "optimizeOriginalTypes": cursor.optimizeOriginalTypes,
                "followRecordedPositionOnHover": cursor.followRecordedPositionOnHover,
                "clickEffect": cursor.clickEffect?.rawValue ?? NSNull(),
            ] as [String: Any],
            "captions": [
                "enableTranscript": captions.enableTranscript,
                "showSoundLabels": captions.showSoundLabels,
                "enableShortcuts": captions.enableShortcuts,
                "hiddenShortcuts": captions.hiddenShortcuts,
                "showShortcutsWithSingleLetters": captions.showShortcutsWithSingleLetters,
                "shortcutsSizeRatio": captions.shortcutsSizeRatio,
                "font": captions.font.rawValue,
                "sizeRatio": captions.sizeRatio,
                "color": captions.color,
                "backgroundColor": captions.backgroundColor,
                "position01": vec(captions.position01),
                "wordsReveal": captions.wordsReveal.rawValue,
                "lineGrowth": captions.lineGrowth.rawValue,
                "wordEntrance": captions.wordEntrance.rawValue,
            ] as [String: Any],
            "audio": [
                "volume": audio.volume,
                "muteMicrophone": audio.muteMicrophone,
                "microphoneAudioPreset": audio.microphoneAudioPreset.rawValue,
                "muteSystemAudio": audio.muteSystemAudio,
                "backgroundAudioVolume": audio.backgroundAudioVolume,
                "backgroundAudioFileName": audio.backgroundAudioFileName ?? NSNull(),
                "muteBackgroundAudio": audio.muteBackgroundAudio,
                "muteExternalDeviceAudio": audio.muteExternalDeviceAudio,
                "clickSoundEffect": audio.clickSoundEffect?.rawValue ?? NSNull(),
                "clickSoundEffectVolume": audio.clickSoundEffectVolume,
            ] as [String: Any],
            "camera": [
                "hide": camera.hide,
                "mirror": camera.mirror,
                "aspectRatio": 1,
                "enableFaceTracking": camera.enableFaceTracking,
                "hideDuringSilenceMs": camera.hideDuringSilenceMs ?? NSNull(),
                "lut": camera.lut ?? NSNull(),
                "lutIntensity": camera.lutIntensity,
                "grain": camera.grain,
                "sharpen01": camera.sharpen01,
                "background": ["blurAmount01": 0, "edgeFalloff01": camera.background.edgeFalloff01],
            ] as [String: Any],
            "animations": [
                "mouseMovementSpring": animation.mouseSpring.map(spring) ?? NSNull(),
                "screenMovementSpring": spring(animation.screenSpring),
                "motionBlurAmount": animation.motionBlurAmount,
            ] as [String: Any],
            "processing": processingJSON,
            "zooms": ["startAnimationEarly": animation.startsZoomEarly],
            "defaultLayout": [
                "type": layout.type.rawValue,
                "cameraOverlay": [
                    "overlayCameraPosition01": vec(layout.cameraOverlay.position01),
                    "overlayCameraSizeRatio01": layout.cameraOverlay.sizeRatio01,
                    "overlayCameraPaddingRatio01": layout.cameraOverlay.paddingRatio01,
                    "overlayCameraAspectRatio": layout.cameraOverlay.aspectRatio,
                    "overlayZoomedCameraScale": layout.cameraOverlay.zoomedScale,
                ] as [String: Any],
                "splitScreen": [
                    "splitDirection": layout.splitScreen.direction.rawValue,
                    "splitFlip": layout.splitScreen.flip,
                    "splitScreenRatio01": layout.splitScreen.screenRatio01 ?? NSNull(),
                    "enablePadding": layout.splitScreen.enablePadding,
                ] as [String: Any],
                "cutoutCamera": [
                    "cutoutCameraPositionX01": layout.cutoutCamera.positionX01,
                    "cutoutCameraSizeRatio01": layout.cutoutCamera.sizeRatio01,
                    "cutoutCameraZoomedScale": layout.cutoutCamera.zoomedScale,
                    "cutoutCameraAspectRatio": layout.cutoutCamera.aspectRatio ?? NSNull(),
                ] as [String: Any],
            ] as [String: Any],
            "device": ["enableMockup": device.enableMockup, "frameKey": device.frameKey ?? NSNull()] as [String: Any],
            "output": [
                "aspectRatio": style.aspectRatio.map { $0 as Any } ?? "auto",
                "paddingRatio01": style.paddingRatio,
                "avoidEmptyZoomArea": style.avoidEmptyZoomArea,
            ] as [String: Any],
            "styles": [
                "screenBorderRadius": style.cornerRadius,
                "cameraBorderRadiusRatio01": style.cameraBorderRadiusRatio,
                "screenInset": [
                    "size": style.inset.size,
                    "origin01": vec(style.inset.origin01),
                    "alpha": style.inset.alpha,
                    "color": style.inset.color.hexString,
                ] as [String: Any],
                "shadow": [
                    "intensity": style.shadow.intensity,
                    "distance": style.shadow.distance,
                    "angle": style.shadow.angle,
                    "blur": style.shadow.blur,
                    "isDirectional": style.shadow.isDirectional,
                ] as [String: Any],
                "background": [
                    "type": style.background.kind.rawValue,
                    "color": style.background.color.hexString,
                    "gradient": [
                        "start": ["x": 0, "y": 0],
                        "end": ["x": 1, "y": 1],
                        "stops": stops.enumerated().map { i, c in ["color": c.hexString, "at": stops.count > 1 ? Double(i) / Double(stops.count - 1) : 0] as [String: Any] },
                    ] as [String: Any],
                    "systemName": style.background.systemName,
                    "image": style.background.imageFileName ?? NSNull(),
                    "unsplash": NSNull(),
                    "blur": style.background.blur,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    // MARK: Reading

    public static func decode(_ data: Data) throws -> PresetConfig {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let json = root["json"] as? [String: Any] else { throw Failure.invalidData }
        let version = json["version"] as? String ?? ""
        guard version.split(separator: ".").first.flatMap({ Int($0) }) != nil else { throw Failure.invalidVersion(version) }
        guard let config = json["projectConfig"] as? [String: Any] else { throw Failure.invalidData }
        return presetConfig(config)
    }

    static func presetConfig(_ c: [String: Any]) -> PresetConfig {
        func dict(_ d: [String: Any]?, _ key: String) -> [String: Any] { d?[key] as? [String: Any] ?? [:] }
        func num(_ d: [String: Any], _ key: String, _ fallback: Double) -> Double { (d[key] as? NSNumber)?.doubleValue ?? fallback }
        func optNum(_ d: [String: Any], _ key: String, _ fallback: Double?) -> Double? {
            if d[key] is NSNull { return nil }
            return (d[key] as? NSNumber)?.doubleValue ?? fallback
        }
        func bool(_ d: [String: Any], _ key: String, _ fallback: Bool) -> Bool { (d[key] as? NSNumber)?.boolValue ?? fallback }
        func str(_ d: [String: Any], _ key: String) -> String? { d[key] as? String }
        func vec(_ d: [String: Any], _ key: String, _ fallback: Vec2) -> Vec2 {
            let v = dict(d, key)
            return Vec2(num(v, "x", fallback.x), num(v, "y", fallback.y))
        }
        func color(_ d: [String: Any], _ key: String, _ fallback: RGBA) -> RGBA { str(d, key).flatMap(RGBA.init(hexString:)) ?? fallback }
        func spring(_ d: [String: Any], _ fallback: SpringConfig) -> SpringConfig {
            var s = fallback
            s.stiffness = num(d, "stiffness", s.stiffness)
            s.damping = num(d, "damping", s.damping)
            s.mass = num(d, "mass", s.mass)
            s.clampOvershoot = bool(d, "clamp", s.clampOvershoot)
            s.precision = num(d, "precision", s.precision)
            return s
        }

        var style = StyleConfig()
        let styles = dict(c, "styles"), output = dict(c, "output")
        style.cornerRadius = num(styles, "screenBorderRadius", style.cornerRadius)
        style.cameraBorderRadiusRatio = num(styles, "cameraBorderRadiusRatio01", style.cameraBorderRadiusRatio)
        let inset = dict(styles, "screenInset")
        style.inset.size = num(inset, "size", style.inset.size)
        style.inset.origin01 = vec(inset, "origin01", style.inset.origin01)
        style.inset.alpha = num(inset, "alpha", style.inset.alpha)
        style.inset.color = color(inset, "color", style.inset.color)
        let shadow = dict(styles, "shadow")
        style.shadow.intensity = num(shadow, "intensity", style.shadow.intensity)
        style.shadow.distance = num(shadow, "distance", style.shadow.distance)
        style.shadow.angle = num(shadow, "angle", style.shadow.angle)
        style.shadow.blur = num(shadow, "blur", style.shadow.blur)
        style.shadow.isDirectional = bool(shadow, "isDirectional", style.shadow.isDirectional)
        let background = dict(styles, "background")
        if let kind = str(background, "type").flatMap(BackgroundKind.init(rawValue:)) { style.background.kind = kind }
        style.background.color = color(background, "color", style.background.color)
        let stops = (dict(background, "gradient")["stops"] as? [[String: Any]] ?? []).compactMap { str($0, "color").flatMap(RGBA.init(hexString:)) }
        if !stops.isEmpty { style.background.gradientStops = stops }
        if let name = str(background, "systemName") { style.background.systemName = name }
        style.background.imageFileName = str(background, "image")
        style.background.blur = num(background, "blur", style.background.blur)
        if let ratio = (output["aspectRatio"] as? NSNumber)?.doubleValue { style.aspectRatio = ratio } else { style.aspectRatio = nil }
        style.paddingRatio = num(output, "paddingRatio01", style.paddingRatio)
        style.avoidEmptyZoomArea = bool(output, "avoidEmptyZoomArea", style.avoidEmptyZoomArea)

        var cursor = CursorConfig()
        let cc = dict(c, "cursor")
        cursor.hide = bool(cc, "hide", cursor.hide)
        cursor.size = num(cc, "size", cursor.size)
        cursor.stopMovementInLastPartMs = num(cc, "stopMovementInLastPartMs", cursor.stopMovementInLastPartMs)
        let set = dict(cc, "set")
        if let id = str(set, "id") { cursor.set = CursorSetChoice(id: id, variants: set["variants"] as? [String: String] ?? [:]) }
        cursor.baseRotation = num(cc, "baseRotation", cursor.baseRotation)
        cursor.alwaysUseDefault = bool(cc, "alwaysUseDefault", cursor.alwaysUseDefault)
        cursor.hideNotMovingAfterMs = optNum(cc, "hideNotMovingAfterMs", cursor.hideNotMovingAfterMs)
        cursor.loopPositionBeforeEndMs = optNum(cc, "loopPositionBeforeEndMs", cursor.loopPositionBeforeEndMs)
        cursor.removeShakeThreshold = num(cc, "removeShakeTreshold", cursor.removeShakeThreshold)
        cursor.optimizeOriginalTypes = bool(cc, "optimizeOriginalTypes", cursor.optimizeOriginalTypes)
        cursor.followRecordedPositionOnHover = bool(cc, "followRecordedPositionOnHover", cursor.followRecordedPositionOnHover)
        cursor.clickEffect = str(cc, "clickEffect").flatMap(ClickEffect.init(rawValue:))

        var animation = AnimationConfig()
        let animations = dict(c, "animations")
        animation.screenSpring = spring(dict(animations, "screenMovementSpring"), animation.screenSpring)
        // Nullable, null by default: no cursor smoothing.
        animation.mouseSpring = (animations["mouseMovementSpring"] as? [String: Any]).map { spring($0, SpringConfig()) }
        animation.motionBlurAmount = num(animations, "motionBlurAmount", animation.motionBlurAmount)
        animation.startsZoomEarly = bool(dict(c, "zooms"), "startAnimationEarly", animation.startsZoomEarly)

        var audio = AudioConfig()
        let ac = dict(c, "audio")
        audio.volume = num(ac, "volume", audio.volume)
        audio.muteMicrophone = bool(ac, "muteMicrophone", audio.muteMicrophone)
        if let preset = str(ac, "microphoneAudioPreset").flatMap(MicrophoneAudioPreset.init(rawValue:)) { audio.microphoneAudioPreset = preset }
        audio.muteSystemAudio = bool(ac, "muteSystemAudio", audio.muteSystemAudio)
        audio.backgroundAudioVolume = num(ac, "backgroundAudioVolume", audio.backgroundAudioVolume)
        audio.backgroundAudioFileName = str(ac, "backgroundAudioFileName")
        audio.muteBackgroundAudio = bool(ac, "muteBackgroundAudio", audio.muteBackgroundAudio)
        audio.muteExternalDeviceAudio = bool(ac, "muteExternalDeviceAudio", audio.muteExternalDeviceAudio)
        audio.clickSoundEffect = str(ac, "clickSoundEffect").flatMap(ClickSoundSet.init(rawValue:))
        audio.clickSoundEffectVolume = num(ac, "clickSoundEffectVolume", audio.clickSoundEffectVolume)

        var camera = CameraConfig()
        let cam = dict(c, "camera")
        camera.hide = bool(cam, "hide", camera.hide)
        camera.mirror = bool(cam, "mirror", camera.mirror)
        camera.enableFaceTracking = bool(cam, "enableFaceTracking", camera.enableFaceTracking)
        camera.hideDuringSilenceMs = optNum(cam, "hideDuringSilenceMs", camera.hideDuringSilenceMs)
        camera.lut = str(cam, "lut")
        camera.lutIntensity = num(cam, "lutIntensity", camera.lutIntensity)
        camera.grain = num(cam, "grain", camera.grain)
        camera.sharpen01 = num(cam, "sharpen01", camera.sharpen01)
        camera.background.edgeFalloff01 = num(dict(cam, "background"), "edgeFalloff01", camera.background.edgeFalloff01)

        var captions = CaptionsConfig()
        let cap = dict(c, "captions")
        captions.enableTranscript = bool(cap, "enableTranscript", captions.enableTranscript)
        captions.showSoundLabels = bool(cap, "showSoundLabels", captions.showSoundLabels)
        captions.enableShortcuts = bool(cap, "enableShortcuts", captions.enableShortcuts)
        captions.hiddenShortcuts = cap["hiddenShortcuts"] as? [String: Bool] ?? captions.hiddenShortcuts
        captions.showShortcutsWithSingleLetters = bool(cap, "showShortcutsWithSingleLetters", captions.showShortcutsWithSingleLetters)
        captions.shortcutsSizeRatio = num(cap, "shortcutsSizeRatio", captions.shortcutsSizeRatio)
        if let font = str(cap, "font").flatMap(CaptionsConfig.Font.init(rawValue:)) { captions.font = font }
        captions.sizeRatio = num(cap, "sizeRatio", captions.sizeRatio)
        if let value = str(cap, "color") { captions.color = value }
        if let value = str(cap, "backgroundColor") { captions.backgroundColor = value }
        captions.position01 = vec(cap, "position01", captions.position01)
        if let value = str(cap, "wordsReveal").flatMap(CaptionsConfig.WordsReveal.init(rawValue:)) { captions.wordsReveal = value }
        if let value = str(cap, "lineGrowth").flatMap(CaptionsConfig.LineGrowth.init(rawValue:)) { captions.lineGrowth = value }
        if let value = str(cap, "wordEntrance").flatMap(CaptionsConfig.WordEntrance.init(rawValue:)) { captions.wordEntrance = value }

        var processing = ProcessingConfig()
        let pc = dict(c, "processing")
        processing.improveRecordingQuality01 = num(pc, "improveRecordingQuality01", processing.improveRecordingQuality01)
        processing.autoMaskSensitiveData = bool(pc, "autoMaskSensitiveData", processing.autoMaskSensitiveData)
        processing.sensitiveDataExpandPx = num(pc, "sensitiveDataExpandPx", processing.sensitiveDataExpandPx)
        processing.sensitiveDataCustomPhrases = pc["sensitiveDataCustomPhrases"] as? [String] ?? processing.sensitiveDataCustomPhrases
        processing.autoMaskFaces = bool(pc, "autoMaskFaces", processing.autoMaskFaces)

        var layout = DefaultCameraLayout()
        let dl = dict(c, "defaultLayout")
        if let type = str(dl, "type").flatMap(CameraLayoutType.init(rawValue:)) { layout.type = type }
        let overlay = dict(dl, "cameraOverlay")
        layout.cameraOverlay.position01 = vec(overlay, "overlayCameraPosition01", layout.cameraOverlay.position01)
        layout.cameraOverlay.sizeRatio01 = num(overlay, "overlayCameraSizeRatio01", layout.cameraOverlay.sizeRatio01)
        layout.cameraOverlay.paddingRatio01 = num(overlay, "overlayCameraPaddingRatio01", layout.cameraOverlay.paddingRatio01)
        layout.cameraOverlay.aspectRatio = num(overlay, "overlayCameraAspectRatio", layout.cameraOverlay.aspectRatio)
        layout.cameraOverlay.zoomedScale = num(overlay, "overlayZoomedCameraScale", layout.cameraOverlay.zoomedScale)
        let split = dict(dl, "splitScreen")
        if let direction = str(split, "splitDirection").flatMap(SplitDirection.init(rawValue:)) { layout.splitScreen.direction = direction }
        layout.splitScreen.flip = bool(split, "splitFlip", layout.splitScreen.flip)
        layout.splitScreen.screenRatio01 = optNum(split, "splitScreenRatio01", layout.splitScreen.screenRatio01)
        layout.splitScreen.enablePadding = bool(split, "enablePadding", layout.splitScreen.enablePadding)
        let cutout = dict(dl, "cutoutCamera")
        layout.cutoutCamera.positionX01 = num(cutout, "cutoutCameraPositionX01", layout.cutoutCamera.positionX01)
        layout.cutoutCamera.sizeRatio01 = num(cutout, "cutoutCameraSizeRatio01", layout.cutoutCamera.sizeRatio01)
        layout.cutoutCamera.zoomedScale = num(cutout, "cutoutCameraZoomedScale", layout.cutoutCamera.zoomedScale)
        layout.cutoutCamera.aspectRatio = optNum(cutout, "cutoutCameraAspectRatio", layout.cutoutCamera.aspectRatio)

        var device = DeviceConfig()
        let dv = dict(c, "device")
        device.enableMockup = bool(dv, "enableMockup", device.enableMockup)
        device.frameKey = str(dv, "frameKey")

        return PresetConfig(style: style, cursor: cursor, animation: animation, audio: audio, camera: camera, captions: captions,
                            processing: processing, defaultLayout: layout, device: device)
    }
}
