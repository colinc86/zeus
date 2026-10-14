#if DEBUG || ZEUS_PERFORMANCE_PROBE
import AppKit
import Foundation
import SwiftUI
import os

/// Isolated scrolling: native clip updates or window-local wheel dispatch. No global event posting.
@MainActor enum ScrollBenchmark {
    static func start(shell: ShellController) {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else { return }
        Task { @MainActor [weak shell] in
            let root = URL(fileURLWithPath: home)
            try? await Task.sleep(for: .seconds(3))
            guard let shell, let scroll = shell.benchmarkScrollView() else {
                write(["ready": false, "reason": "Conversation scroll view did not mount"], to: root.appendingPathComponent("scroll-ready.json"))
                return
            }
            shell.orderPerformanceSurfacesFront()
            try? await Task.sleep(for: .milliseconds(200))
            let readiness = availability(of: scroll)
            write(readiness, to: root.appendingPathComponent("scroll-ready.json"))
            guard readiness["ready"] as? Bool == true else { return }
            let trigger = root.appendingPathComponent("scroll-start")
            let deadline = ContinuousClock.now + .seconds(120)
            while !FileManager.default.fileExists(atPath: trigger.path), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let environment = ProcessInfo.processInfo.environment
            let localEvents = environment["ZEUS_PERF_INPUT"] == "local-events"
            let pauseAvatar = environment["ZEUS_PERF_PAUSE_AVATAR"] == "1"
            if pauseAvatar { shell.setPerformanceAvatarPaused(true) }
            shell.cardPanelState.keyboardScroll = .oldest
            shell.cardPanelState.keyboardScrollRequest += 1
            try? await Task.sleep(for: .seconds(1))
            let log = OSLog(subsystem: "dev.zeus.scroll-benchmark", category: .pointsOfInterest)
            let initialNativeOffset = scroll.contentView.bounds.minY
            let initialSwiftUIOffset = shell.cardPanelState.viewportForDiagnostics.offset
            let initialComposition = composition(of: scroll)
            let started = ProcessInfo.processInfo.systemUptime
            var ticks = 0, largestInterval = 0.0, previous = started
            var endpoints: [Double] = []
            var surfaceValid = true
            var eventCount = 0
            var eventError = false
            var nextHealthCheck = started
            os_signpost(.begin, log: log, name: "Scroll round trip")
            for direction in [1.0, -1.0] {
                if eventError { break }
                let legStart = ProcessInfo.processInfo.systemUptime
                var firstEvent = true
                let legOffset = scroll.contentView.bounds.minY
                while ProcessInfo.processInfo.systemUptime - legStart < 90 {
                    let now = ProcessInfo.processInfo.systemUptime
                    let delta = now - previous
                    largestInterval = max(largestInterval, delta)
                    previous = now; ticks += 1
                    if now >= nextHealthCheck {
                        surfaceValid = surfaceValid && (availability(of: scroll)["ready"] as? Bool == true)
                        nextHealthCheck = now + 0.5
                    }
                    guard shell.cardPanelState.isVisible, surfaceValid, scroll.window?.isVisible == true, shell.surfaceActivity.conversation else {
                        surfaceValid = false; break
                    }
                    guard let document = scroll.documentView else { break }
                    let clip = scroll.contentView
                    let maximum = max(0, document.bounds.height - clip.bounds.height)
                    let current = document.isFlipped ? clip.bounds.minY : maximum - clip.bounds.minY
                    if localEvents, now - legStart > 3, abs(clip.bounds.minY - legOffset) < 5 {
                        eventError = true; break
                    }
                    // 2400 pt/s, eased into each leg. Integrate monotonic time rather than tick count.
                    let ramp = min(1, (now - legStart) / 0.2)
                    let next = min(maximum, max(0, current + direction * 2400 * delta * ramp))
                    if localEvents {
                        let distance = Int32((next - current).rounded())
                        if let event = wheelEvent(scroll: scroll, delta: -distance, phase: firstEvent ? .began : .changed) {
                            scroll.window?.sendEvent(event)
                            eventCount += 1; firstEvent = false
                        } else { eventError = true; break }
                    } else {
                        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: document.isFlipped ? next : maximum - next))
                        scroll.reflectScrolledClipView(clip)
                    }
                    let actual = document.isFlipped ? clip.bounds.minY : maximum - clip.bounds.minY
                    if (direction > 0 && actual >= maximum - 0.5) || (direction < 0 && actual <= 0.5) {
                        endpoints.append(actual); break
                    }
                    try? await Task.sleep(for: .seconds(1.0 / 120))
                }
                if localEvents, let event = wheelEvent(scroll: scroll, delta: 0, phase: .ended) {
                    scroll.window?.sendEvent(event); eventCount += 1
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            os_signpost(.end, log: log, name: "Scroll round trip")
            let result: [String: Any] = ["duration_s": ProcessInfo.processInfo.systemUptime - started,
                "initial_native_offset": initialNativeOffset, "initial_swiftui_offset": initialSwiftUIOffset,
                "final_native_offset": scroll.contentView.bounds.minY, "final_swiftui_offset": shell.cardPanelState.viewportForDiagnostics.offset,
                "document_height": scroll.documentView?.bounds.height ?? 0, "clip_width": scroll.contentView.bounds.width,
                "input": localEvents ? "window-local wheel" : "clip", "wheel_events": eventCount, "event_error": eventError,
                "scroll_phases": shell.cardPanelState.scrollPhasesForDiagnostics,
                "responsive_scroll_compatible": type(of: scroll).isCompatibleWithResponsiveScrolling,
                "window_opaque": scroll.window?.isOpaque ?? false, "window_background_alpha": scroll.window?.backgroundColor.alphaComponent ?? 0,
                "font": shell.settings.fontChoice.rawValue, "avatar_paused": pauseAvatar, "avatar_active_during_scroll": shell.surfaceActivity.avatar,
                "composition_start": initialComposition, "composition_end": composition(of: scroll),

                "ticks": ticks, "requested_hz": 120, "speed_points_s": 2400,
                "max_callback_interval_ms": largestInterval * 1000, "endpoints": endpoints,
                "completed": endpoints.count == 2 && surfaceValid && !eventError, "surface_valid": surfaceValid, "cards": shell.cards.cards.count,
                "visibility": shell.performanceVisibility, "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
                "screen_max_hz": scroll.window?.screen?.maximumFramesPerSecond ?? 0]
            if pauseAvatar { shell.setPerformanceAvatarPaused(false) }
            write(result, to: root.appendingPathComponent("scroll-result.json"))
        }
    }

    static func availability(of scroll: NSScrollView) -> [String: Any] {
        let window = scroll.window
        let id = (window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let awake = id.map { CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0 } ?? false
        let visible = window?.isVisible == true && window?.occlusionState.contains(.visible) == true
        return ["ready": awake && visible, "display_awake": awake, "window_visible": visible,
                "display_id": id ?? 0, "screen_max_hz": window?.screen?.maximumFramesPerSecond ?? 0,
                "reason": !awake ? "The panel display is asleep or inactive" : !visible ? "The panel is occluded (including a locked session)" : "Ready"]
    }
    private static func write(_ value: [String: Any], to url: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// CoreGraphics creates the event payload; only the isolated window receives it. The CG event
    /// is never posted to a HID/session tap. NSEvent's unattached CG coordinates are translated
    /// into the window-local point used by NSWindow.sendEvent.
    static func wheelEvent(scroll: NSScrollView, delta: Int32, phase: CGScrollPhase) -> NSEvent? {
        guard let window = scroll.window, let screen = window.screen,
              let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { return nil }
        let point = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        event.location = CGPoint(x: point.x, y: primaryTop - point.y)
        event.timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1e9)
        event.flags = []
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64(delta) * 65536)
        event.setDoubleValueField(.scrollWheelEventRawDeltaAxis1, value: Double(delta))
        return NSEvent(cgEvent: event)
    }

    /// Read-only native backing-layer census, outside the timed traversal. SwiftUI render nodes
    /// inside a backing layer are not separate CALayers, so this is not a render-node count.
    static func composition(of view: NSView) -> [String: Int] {
        var views = 0, hosts = 0, layers = 0, opaque = 0, masks = 0, shadows = 0, rasterized = 0
        var visited: Set<ObjectIdentifier> = []
        func inspectLayer(_ layer: CALayer) {
            guard visited.insert(ObjectIdentifier(layer)).inserted else { return }
            layers += 1
            if layer.isOpaque { opaque += 1 }
            if layer.mask != nil || layer.masksToBounds { masks += 1 }
            if layer.shadowOpacity > 0 { shadows += 1 }
            if layer.shouldRasterize { rasterized += 1 }
            if let mask = layer.mask { inspectLayer(mask) }
            for child in layer.sublayers ?? [] { inspectLayer(child) }
        }
        func inspectView(_ view: NSView) {
            views += 1
            if view is any ScrollHostingMarker { hosts += 1 }
            if let layer = view.layer { inspectLayer(layer) }
            for child in view.subviews { inspectView(child) }
        }
        inspectView(view)
        return ["views": views, "hosting_views": hosts, "layers": layers, "opaque_layers": opaque,
                "masked_layers": masks, "shadow_layers": shadows, "rasterized_layers": rasterized]
    }

}
private protocol ScrollHostingMarker {}
extension NSHostingView: ScrollHostingMarker {}
#endif
