#if DEBUG
import AppKit
import Foundation
import CoreGraphics

/// Opt-in P10 diagnostics for isolated Debug launches. Counts native layer updates,
/// including actual RGBA changes, rather than treating timer wakes as animation.
@MainActor
enum DebugSpriteFrameCounter {
    struct Counts {
        private(set) var assignments = 0
        private(set) var pixelChanges = 0
        private var lastPixels: Data?

        mutating func record(_ image: CGImage) {
            assignments += 1
            guard let provider = image.dataProvider, let data = provider.data else { return }
            let pixels = data as Data
            if pixels != lastPixels {
                pixelChanges += 1
                lastPixels = pixels
            }
        }
    }

    private final class Entry {
        let id = UUID().uuidString
        weak var view: PixelSpriteLayerView?
        var counts = Counts()
        init(view: PixelSpriteLayerView) { self.view = view }
    }
    private static let enabled = ProcessInfo.processInfo.environment["ZEUS_FRAME_COUNTER"] == "1"
        && ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil
    private static var entries: [ObjectIdentifier: Entry] = [:]
    private static var timer: Task<Void, Never>?

    static func record(view: PixelSpriteLayerView, image: CGImage) {
        guard enabled else { return }
        let id = ObjectIdentifier(view)
        let entry = entries[id].flatMap { $0.view === view ? $0 : nil } ?? Entry(view: view)
        entry.counts.record(image)
        entries[id] = entry
        if timer == nil {
            timer = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    emit()
                }
            }
        }
    }

    private static func emit() {
        entries = entries.filter { $0.value.view != nil }
        let serverWindows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let windows: [[String: Any]] = NSApp.windows.map { window in
            let index = serverWindows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
            let server = index.map { serverWindows[$0] }
            let displayID = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
            func bounds(_ info: [String: Any]) -> CGRect? {
                guard let dictionary = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
                return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
            }
            let intersectsAbove: Int = if let index, let server, let rect = bounds(server) {
                serverWindows.prefix(index).filter {
                    ($0[kCGWindowIsOnscreen as String] as? Bool) == true
                        && ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0
                        && bounds($0)?.intersects(rect) == true
                }.count
            } else { -1 }
            return ["title": window.title, "number": window.windowNumber, "ordered": window.isVisible,
                "occlusionVisible": window.occlusionState.contains(.visible), "occlusionRaw": window.occlusionState.rawValue,
                "onScreen": server?[kCGWindowIsOnscreen as String] as? Bool ?? false,
                "alpha": server?[kCGWindowAlpha as String] as? Double ?? 0,
                "intersectingWindowsAbove": intersectsAbove,
                "displayAsleep": displayID.map { CGDisplayIsAsleep($0) != 0 } as Any? ?? NSNull(),
                "x": window.frame.minX, "y": window.frame.minY,
                "width": window.frame.width, "height": window.frame.height]
        }
        let views: [[String: Any]] = entries.compactMap { _, entry in
            guard let view = entry.view else { return nil }
            let contentsMatch = (view.layer?.contents as AnyObject?) === view.driver.image
            return ["id": entry.id, "window": view.window?.windowNumber ?? -1,
                "surface": view.window?.title ?? "detached", "assignments": entry.counts.assignments,
                "pixelChanges": entry.counts.pixelChanges, "driverAssignments": view.driver.imageAssignments,
                "interval": view.driver.scheduledInterval as Any? ?? NSNull(), "layerMatchesDriver": contentsMatch]
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        // This optional QA flag is present when locked; an available dictionary without it means unlocked.
        let sessionLocked = session.map { ($0["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false }
        let sample: [String: Any] = ["timestamp": Date().timeIntervalSince1970,
            "uptime": ProcessInfo.processInfo.systemUptime, "pid": ProcessInfo.processInfo.processIdentifier,
            "appActive": NSApp.isActive, "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            // Private session-dictionary key: QA evidence only, never a production gate.
            "sessionLocked": sessionLocked as Any? ?? NSNull(),
            "ignoreOcclusion": ProcessInfo.processInfo.environment["ZEUS_PERF_IGNORE_OCCLUSION"] == "1",
            "windows": windows, "views": views]
        guard let data = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]) else { return }
        var line = Data("ZEUS_FRAMES: ".utf8); line.append(data); line.append(10)
        FileHandle.standardOutput.write(line)
    }
}
#endif
