import AppKit
import Carbon
import CoreMediaIO

/// Camera state uses property listeners; no camera is opened and no audio/video is read.
@MainActor final class ScreenSafetyMonitor {
    private var devices: [CMIOObjectID] = []
    private var installed = false
    private var listenerFailed = false
    private let queue = DispatchQueue(label: "Zeus.camera-state", qos: .utility)
    private var listener: CMIOObjectPropertyListenerBlock?
    private(set) var cameraInUse = true // Unknown/enumeration failure is a hard stop.
    var onChange: (() -> Void)?
    isolated deinit { stop() }
    func start() {
        guard !installed else { return }; installed = true; listenerFailed = false
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in Task { @MainActor [weak self] in self?.refresh() } }
        listener = block
        var address = Self.address(kCMIOHardwarePropertyDevices)
        listenerFailed = CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue, block) != noErr
        refresh()
    }
    func stop() {
        guard installed, let listener else { return }; installed = false
        var address = Self.address(kCMIOHardwarePropertyDevices)
        CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue, listener)
        address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        for device in devices { CMIOObjectRemovePropertyListenerBlock(device, &address, queue, listener) }
        devices = []; self.listener = nil
    }
    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        let scope = selector == kCMIOHardwarePropertyDevices ? UInt32(kCMIOObjectPropertyScopeGlobal) : UInt32(kCMIOObjectPropertyScopeWildcard)
        let element = selector == kCMIOHardwarePropertyDevices ? UInt32(kCMIOObjectPropertyElementMain) : UInt32(kCMIOObjectPropertyElementWildcard)
        return .init(mSelector: CMIOObjectPropertySelector(selector), mScope: scope, mElement: element)
    }
    private func refresh() {
        guard installed else { return }
        var address = Self.address(kCMIOHardwarePropertyDevices), size: UInt32 = 0
        var next: [CMIOObjectID] = []
        var failed = CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) != noErr
        if !failed {
            next = Array(repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
            failed = next.withUnsafeMutableBytes { CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &size, $0.baseAddress) } != noErr
        }
        address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        if let listener {
            for device in devices where !next.contains(device) { CMIOObjectRemovePropertyListenerBlock(device, &address, queue, listener) }
            for device in next where !devices.contains(device) {
                if CMIOObjectAddPropertyListenerBlock(device, &address, queue, listener) != noErr { listenerFailed = true }
            }
        }
        devices = next
        if failed { listenerFailed = true }
        let running = readRunningState()
        if running != cameraInUse { cameraInUse = running; onChange?() }
    }
    private func readRunningState() -> Bool {
        guard installed, !listenerFailed else { return true }
        var address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        return devices.contains { device in
            var value: UInt32 = 0, used = UInt32(MemoryLayout<UInt32>.size)
            return CMIOObjectGetPropertyData(device, &address, 0, nil, used, &used, &value) != noErr || value != 0
        }
    }
    /// Called at every capture/storage boundary; context supplies lock/private/presentation state too.
    func supplement(_ context: ScreenContext) -> ScreenContext {
        var result = context
        result.cameraInUse = result.cameraInUse || readRunningState()
        result.secureInput = result.secureInput || IsSecureEventInputEnabled()
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(0, nil, &count) != .success { result.isMirrored = true }
        else {
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if CGGetOnlineDisplayList(count, &displays, &count) != .success { result.isMirrored = true }
            else { result.isMirrored = result.isMirrored || displays.contains { CGDisplayIsInMirrorSet($0) != 0 } }
        }
        if ["com.apple.iWork.Keynote", "com.microsoft.Powerpoint"].contains(result.bundleID),
           let display = NSScreen.main, let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, result.windowID) as? [[String: Any]],
           let window = windows.first, let bounds = window[kCGWindowBounds as String] as? [String: Any],
           let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width >= display.frame.width - 2, rect.height >= display.frame.height - 2 {
            result.isPresenting = true
        }
        return result
    }
}
