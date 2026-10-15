import AppKit
import Carbon

enum TypingKey: Equatable, Sendable {
    case text(String), backspace, paste(changeCount: Int), ime, invalidate
}
@MainActor protocol TypingEventSource: AnyObject {
    var hasPermission: Bool { get }
    func requestPermission() -> Bool
    func start(shouldRead: @escaping () -> Bool, onKey: @escaping (TypingKey) -> Void,
               onDisabled: @escaping () -> Void) -> Bool
    func resetTranslation()
    func stop()
}

/// Retains the layout data while UCKeyTranslate uses its pointer; dead keys belong to one run only.
@MainActor struct TypingKeyTranslator {
    private let data: CFData
    private var deadKeys: UInt32 = 0
    init?(sourceID: String? = nil) {
        let source: TISInputSource?
        if let sourceID {
            source = (TISCreateInputSourceList([kTISPropertyInputSourceID as String: sourceID] as CFDictionary, true)?
                .takeRetainedValue() as? [TISInputSource])?.first
        } else { source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() }
        guard let source, let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
    }
    static var currentSourceID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
    static var isIME: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return true }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String == kTISTypeKeyboardInputMode as String
    }
    /// Backspace cancels an uncommitted accent rather than removing the preceding character from the run.
    mutating func cancelPendingDeadKey() -> Bool {
        let pending = deadKeys != 0; deadKeys = 0; return pending
    }
    mutating func text(code: UInt16, flags: CGEventFlags) -> String {
        guard let bytes = CFDataGetBytePtr(data) else { return "" }
        var modifiers: UInt32 = 0
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey >> 8) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey >> 8) }
        if flags.contains(.maskAlphaShift) { modifiers |= UInt32(alphaLock >> 8) }
        var chars = [UniChar](repeating: 0, count: 8), length = 0
        let status = UCKeyTranslate(UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self), code,
            UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()), 0, &deadKeys, chars.count, &length, &chars)
        guard status == noErr else { return "" }
        return String(utf16CodeUnits: chars, count: length).replacingOccurrences(of: "\r", with: "\n")
    }
}

/// Listen-only. The production path accepts hardware-origin key-downs only and never reads pasteboard contents.
@MainActor final class MacTypingEventSource: TypingEventSource {
    private var tap: CFMachPort?
    private var loopSource: CFRunLoopSource?
    private var shouldRead: (() -> Bool)?
    private var onKey: ((TypingKey) -> Void)?
    private var onDisabled: (() -> Void)?
    private var translator: TypingKeyTranslator?
    private var sourceID: String?
    private let pasteboardChangeCount: () -> Int
    private let fixtureMarker: Int64?
    var hasPermission: Bool { CGPreflightListenEventAccess() }
    init(pasteboardChangeCount: @escaping () -> Int = { NSPasteboard.general.changeCount }) {
        self.pasteboardChangeCount = pasteboardChangeCount; fixtureMarker = nil
    }
    /// Native harness only: per-process tap and an explicit marker, before any key data is inspected.
    /// It cannot listen to another process or accept unmarked real input.
    init(ownedProcessFixtureMarker: Int64, pasteboardChangeCount: @escaping () -> Int) {
        fixtureMarker = ownedProcessFixtureMarker; self.pasteboardChangeCount = pasteboardChangeCount
    }
    func requestPermission() -> Bool { CGRequestListenEventAccess() }
    func resetTranslation() { translator = nil; sourceID = nil }
    func start(shouldRead: @escaping () -> Bool, onKey: @escaping (TypingKey) -> Void,
               onDisabled: @escaping () -> Void) -> Bool {
        stop(); guard hasPermission else { return false }
        self.shouldRead = shouldRead; self.onKey = onKey; self.onDisabled = onDisabled
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            MainActor.assumeIsolated {
                Unmanaged<MacTypingEventSource>.fromOpaque(refcon).takeUnretainedValue().receive(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        if fixtureMarker != nil {
            tap = CGEvent.tapCreateForPid(pid: getpid(), place: .headInsertEventTap, options: .listenOnly,
                                         eventsOfInterest: mask, callback: callback, userInfo: pointer)
        } else {
            tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                   eventsOfInterest: mask, callback: callback, userInfo: pointer)
        }
        guard let tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { stop(); return false }
        loopSource = source; CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true); return true
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let loopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), loopSource, .commonModes) }
        tap = nil; loopSource = nil; shouldRead = nil; onKey = nil; onDisabled = nil; resetTranslation()
    }
    isolated deinit { stop() }
    private func receive(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { onDisabled?(); return }
        guard type == .keyDown else { return }
        if let fixtureMarker {
            guard event.getIntegerValueField(.eventSourceUserData) == fixtureMarker else { return }
        } else {
            guard event.getIntegerValueField(.eventSourceStateID) == CGEventSourceStateID.hidSystemState.rawValue else { return }
        }
        guard shouldRead?() == true else { resetTranslation(); return }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)), flags = event.flags
        let id = TypingKeyTranslator.currentSourceID
        if sourceID != id { translator = TypingKeyTranslator(); sourceID = id }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            if flags.contains(.maskCommand), !flags.contains(.maskControl), translator?.text(code: code, flags: []) == "v" {
                onKey?(.paste(changeCount: pasteboardChangeCount()))
            } else { onKey?(.invalidate) }
            resetTranslation(); return
        }
        if code == 51 {
            if translator?.cancelPendingDeadKey() != true { onKey?(.backspace) }
            return
        }
        if [48, 53, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(code) { onKey?(.invalidate); resetTranslation(); return }
        if TypingKeyTranslator.isIME { onKey?(.ime); return }
        if let text = translator?.text(code: code, flags: flags), !text.isEmpty { onKey?(.text(text)) }
    }
}
