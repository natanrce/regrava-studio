@preconcurrency import AVFoundation
import Combine
import CoreMediaIO
import Foundation

/// A USB-connected iPhone or iPad (`ExternalDevice`).
public struct ExternalDevice: Hashable, Sendable, Identifiable {
    public enum Availability: String, Sendable {
        case available
        /// The user has to trust this Mac on the device.
        case tapTrustOnDevice
        case reconnectCable
    }

    /// `AVCaptureDevice.uniqueID`.
    public var deviceId: String
    /// "Tom's iPhone".
    public var name: String
    public var availability: Availability
    /// "iPhone17,1".
    public var modelId: String?
    /// "iPhone 16 Pro".
    public var modelMarketingName: String?
    public var finish: String?

    public var id: String { deviceId }

    /// "{name} ({modelMarketingName})", or the name alone.
    public var menuLabel: String { modelMarketingName.map { "\(name) (\($0))" } ?? name }

    /// "iPhone", "iPad" or "Device", from the marketing name.
    public var kind: String {
        if modelMarketingName?.contains("iPhone") == true { return "iPhone" }
        if modelMarketingName?.contains("iPad") == true { return "iPad" }
        return "Device"
    }
}

/// Lists iPhones and iPads connected by cable, now and whenever that changes.
@MainActor
public final class ExternalDeviceDiscovery: ObservableObject {
    public static let shared = ExternalDeviceDiscovery()

    @Published public private(set) var devices: [ExternalDevice] = []

    private var session: AVCaptureDevice.DiscoverySession?
    private var devicesObservation: NSKeyValueObservation?
    private var suspendedObservations: [NSKeyValueObservation] = []
    private var cmioListener: CMIOObjectPropertyListenerBlock?
    private let mobileDevice = MobileDeviceObserver()

    private init() {}

    /// Lets AVFoundation see device screens (`kCMIOHardwarePropertyAllowScreenCaptureDevices`) and
    /// starts watching. Devices appear asynchronously after this.
    public func start() {
        guard session == nil else { return }
        Self.allowScreenCaptureDevices()
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
        self.session = session
        devicesObservation = session.observe(\.devices, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        // CMIO device list changes ("Update to devices, updating...").
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        cmioListener = listener
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, DispatchQueue.main, listener)
        mobileDevice.onChange = { [weak self] in self?.refresh() }
        mobileDevice.start()
    }

    static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    private func refresh() {
        let captureDevices = (session?.devices ?? []).filter(\.isConnected)
        suspendedObservations = captureDevices.map { device in
            device.observe(\.isSuspended, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        let list = captureDevices.map { device -> ExternalDevice in
            let info = mobileDevice.info(matching: device.uniqueID)
            var availability = ExternalDevice.Availability.available
            if info?.isPaired == false { availability = .tapTrustOnDevice } else if device.isSuspended { availability = .reconnectCable }
            return ExternalDevice(
                deviceId: device.uniqueID,
                name: info?.deviceName ?? device.localizedName,
                availability: availability,
                modelId: info?.productType,
                modelMarketingName: info?.marketingName ?? info?.productType.map(Self.fallbackMarketingName),
                finish: info?.color
            )
        }
        // Sorted by marketing name, then name, then id.
        let sorted = list.sorted { ($0.modelMarketingName ?? "", $0.name, $0.deviceId) < ($1.modelMarketingName ?? "", $1.name, $1.deviceId) }
        if sorted != devices { devices = sorted }
    }

    /// Fallback names for models not in the table.
    static func fallbackMarketingName(_ productType: String) -> String {
        if productType.hasPrefix("iPhone") { return "iPhone (unknown model)" }
        if productType.hasPrefix("iPad") { return "iPad (unknown model)" }
        if productType.hasPrefix("iPod") { return "iPod (unknown model)" }
        return "iOS Device (unknown model)"
    }
}

/// Apple's private MobileDevice framework, loaded at run time: the device name, model, colour
/// and whether it trusts this Mac. Without it, devices are still listed from AVFoundation, just
/// without those details.
@MainActor
final class MobileDeviceObserver {
    struct Info {
        var identifier: String
        var deviceName: String?
        var productType: String?
        var marketingName: String?
        var color: String?
        var isPaired: Bool
    }

    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias Subscribe = @convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    private typealias CopyIdentifier = @convention(c) (UnsafeMutableRawPointer?) -> Unmanaged<CFString>?
    private typealias DeviceCall = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias CopyValue = @convention(c) (UnsafeMutableRawPointer?, CFString?, CFString?) -> Unmanaged<CFTypeRef>?

    private struct API {
        var subscribe: Subscribe
        var copyIdentifier: CopyIdentifier
        var connect: DeviceCall
        var disconnect: DeviceCall
        var isPaired: DeviceCall
        var copyValue: CopyValue
    }

    private var api: API?
    private var notification: UnsafeMutableRawPointer?
    private var infos: [String: Info] = [:]
    var onChange: (() -> Void)?

    func start() {
        guard api == nil else { return }
        let path = "/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"
        guard let handle = dlopen(path, RTLD_NOW) else { return }
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let subscribe = symbol("AMDeviceNotificationSubscribe", as: Subscribe.self),
              let copyIdentifier = symbol("AMDeviceCopyDeviceIdentifier", as: CopyIdentifier.self),
              let connect = symbol("AMDeviceConnect", as: DeviceCall.self),
              let disconnect = symbol("AMDeviceDisconnect", as: DeviceCall.self),
              let isPaired = symbol("AMDeviceIsPaired", as: DeviceCall.self),
              let copyValue = symbol("AMDeviceCopyValue", as: CopyValue.self) else { return }
        api = API(subscribe: subscribe, copyIdentifier: copyIdentifier, connect: connect, disconnect: disconnect, isPaired: isPaired, copyValue: copyValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        _ = subscribe({ info, context in
            guard let info, let context else { return }
            let observer = Unmanaged<MobileDeviceObserver>.fromOpaque(context).takeUnretainedValue()
            // `am_device_notification_callback_info`: { AMDeviceRef device; uint32 msg; … }.
            let device = info.load(as: UnsafeMutableRawPointer?.self)
            let message = info.load(fromByteOffset: MemoryLayout<UnsafeMutableRawPointer?>.size, as: UInt32.self)
            MainActor.assumeIsolated { observer.handle(device: device, message: message) }
        }, 0, 0, context, &notification)
    }

    /// 1 = connected, 2 = disconnected.
    private func handle(device: UnsafeMutableRawPointer?, message: UInt32) {
        guard let api, let device, let identifier = api.copyIdentifier(device)?.takeRetainedValue() as String? else { return }
        if message == 2 {
            infos[identifier] = nil
        } else if message == 1 {
            var info = Info(identifier: identifier, isPaired: api.isPaired(device) != 0)
            if api.connect(device) == 0 {
                func value(_ key: String) -> String? {
                    api.copyValue(device, nil, key as CFString)?.takeRetainedValue() as? String
                }
                info.deviceName = value("DeviceName")
                info.productType = value("ProductType")
                info.marketingName = value("MarketingName")
                info.color = value("DeviceEnclosureColor") ?? value("DeviceColor")
                _ = api.disconnect(device)
            }
            infos[identifier] = info
        }
        onChange?()
    }

    /// The device whose identifier matches an `AVCaptureDevice.uniqueID` (dashes and case aside).
    func info(matching uniqueID: String) -> Info? {
        func normal(_ s: String) -> String { s.replacingOccurrences(of: "-", with: "").uppercased() }
        let id = normal(uniqueID)
        return infos.values.first { normal($0.identifier) == id || id.contains(normal($0.identifier)) || normal($0.identifier).contains(id) }
    }
}
