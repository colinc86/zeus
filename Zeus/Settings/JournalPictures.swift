import AppKit
import Foundation
import ImageIO
import Observation

struct JournalPicture: Identifiable, Equatable {
    let id: String
    let frameRecord: JournalItem?
    let descriptionRecord: JournalItem?
    var time: Date { (descriptionRecord ?? frameRecord)?.time ?? .distantPast }
    var app: String? { (descriptionRecord ?? frameRecord)?.app }
    var metadata: JournalPayload? { (descriptionRecord ?? frameRecord)?.payload.value }
    var description: String { (descriptionRecord ?? frameRecord)?.payload.value.description ?? "" }
    var windowTitle: String { metadata?.details["window"] ?? "" }
    func missingCaption(now: Date) -> String {
        if metadata?.details["picture_not_kept"] == "private" { return "Picture not kept: it looked private" }
        if metadata?.details["picture_not_kept"] == "deletedByUser" { return "Picture deleted by you" }
        return expiresAt <= now ? "Picture deleted after 7 days" : "Picture deleted by you"
    }
    var expiresAt: Date { Calendar.current.date(byAdding: .day, value: 7, to: time) ?? time }
    func caption(now: Date, hasPicture: Bool) -> String {
        guard hasPicture else { return missingCaption(now: now) }
        let days = max(0, Int(ceil(expiresAt.timeIntervalSince(now) / 86_400)))
        return "Picture · \(days) \(days == 1 ? "day" : "days") left"
    }
}

enum JournalTimelineRow: Identifiable {
    case record(JournalItem), picture(JournalPicture), typing(JournalTypingGroup)
    var id: String { switch self { case .record(let item): "record:" + item.id; case .picture(let item): "picture:" + item.id; case .typing(let group): group.id } }
    var time: Date { switch self { case .record(let item): item.time; case .picture(let item): item.time; case .typing(let group): group.time } }
    static func grouped(_ shown: [JournalItem], catalog: [JournalItem], calendar: Calendar = .current) -> [Self] {
        let frames = Dictionary(catalog.filter { $0.kind == .frame }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let descriptions = Dictionary(catalog.filter { $0.kind == .description && $0.payload.value.details["frame_id"] != nil }
            .map { ($0.payload.value.details["frame_id"] ?? $0.id, $0) }, uniquingKeysWith: { _, last in last })
        var result: [Self] = [], added: Set<String> = []
        for item in shown {
            if item.level == .typed && item.kind == .typedText { continue }
            let frameID = item.kind == .frame ? item.id : item.kind == .description ? item.payload.value.details["frame_id"] : nil
            if item.level == .screen, let frameID {
                if added.insert(frameID).inserted { result.append(.picture(.init(id: frameID, frameRecord: frames[frameID], descriptionRecord: descriptions[frameID]))) }
            } else { result.append(.record(item)) }
        }
        result.sort { $0.time == $1.time ? $0.id < $1.id : $0.time > $1.time }
        // Typing is grouped by app, then hour, rather than interleaving stretches from different apps.
        let totals = Dictionary(uniqueKeysWithValues: JournalTypingGroup.grouped(catalog.filter { $0.level == .typed && $0.kind == .typedText }.map(JournalTypingRun.init), calendar: calendar).map { ($0.id, $0.runs.count) })
        result += JournalTypingGroup.grouped(shown.filter { $0.level == .typed && $0.kind == .typedText }.map(JournalTypingRun.init), calendar: calendar).map {
            var group = $0; group.totalCount = totals[group.id] ?? group.runs.count; return Self.typing(group)
        }
        return result
    }
}

/// Reads only already-covered bytes through the encrypted store's explicit local-viewer capability.
@MainActor @Observable final class JournalPictureModel {
    @ObservationIgnored let journal: any JournalStore
    @ObservationIgnored let clock: () -> Date
    @ObservationIgnored var beforeDelete: () -> Void = {}
    @ObservationIgnored var didChange: () -> Void = {}
    private(set) var rows: [JournalPicture] = []
    var selectedID: String?
    private(set) var error: String?
    private(set) var deleted: FrameDeletionReceipt?
    var confirmsDeleteBoth = false
    @ObservationIgnored private var undoDeadline: Date?
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private var cachedRevision: UInt64 = .max
    @ObservationIgnored private var frames: [String: Redacted<FrameItem>] = [:]
    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored private var thumbnails: [String: NSImage] = [:]
    init(journal: any JournalStore, clock: @escaping () -> Date = Date.init) { self.journal = journal; self.clock = clock }
    var selected: JournalPicture? { rows.first { $0.id == selectedID } }
    func update(_ rows: [JournalTimelineRow]) {
        self.rows = rows.compactMap { if case .picture(let picture) = $0 { picture } else { nil } }
        if cachedRevision != journal.revision {
            cachedRevision = journal.revision; frames.removeAll(); missing.removeAll(); thumbnails.removeAll()
        }
        if let selectedID, !self.rows.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
    func frame(_ picture: JournalPicture) -> Redacted<FrameItem>? {
        if let frame = frames[picture.id] { return frame }
        guard !missing.contains(picture.id), let store = journal as? any FrameJournalStoring else { return nil }
        do {
            guard let frame = try store.frame(id: picture.id) else { missing.insert(picture.id); return nil }
            if frames.count >= 16 { frames.removeAll(); thumbnails.removeAll() }
            frames[picture.id] = frame; return frame
        } catch { missing.insert(picture.id); self.error = "Couldn't read this picture. Nothing was deleted."; return nil }
    }
    func thumbnail(_ picture: JournalPicture) -> NSImage? {
        if let image = thumbnails[picture.id] { return image }
        guard let frame = frame(picture), let source = CGImageSourceCreateWithData(frame.value.heic as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 192] as CFDictionary) else { return nil }
        let value = NSImage(cgImage: image, size: .zero); thumbnails[picture.id] = value; return value
    }
    func caption(_ picture: JournalPicture) -> String { picture.caption(now: clock(), hasPicture: frame(picture) != nil) }
    func delete(_ picture: JournalPicture, includingDescription: Bool) {
        guard let store = journal as? any FrameJournalStoring else { return }
        beforeDelete(); forgetUndo()
        do {
            let receipt = try store.deleteFrame(id: picture.id, includingDescription: includingDescription)
            if !includingDescription {
                deleted = receipt; undoDeadline = clock().addingTimeInterval(5)
                undoTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.forgetUndo()
                }
            }
            confirmsDeleteBoth = false; error = nil; didChange()
        } catch { self.error = "Couldn't delete this picture. Try again." }
    }
    func undoDelete() {
        guard let deleted, let deadline = undoDeadline, clock() < deadline,
              let store = journal as? any FrameJournalStoring else { forgetUndo(); return }
        do { try store.restoreFrame(deleted); forgetUndo(); error = nil; didChange() }
        catch { self.error = "Couldn't restore this picture. It may have changed." }
    }
    func forgetUndo() { undoTask?.cancel(); undoTask = nil; deleted = nil; undoDeadline = nil }
    /// Left means earlier in time, Right later, within the filtered pictures on this day.
    func step(_ offset: Int) {
        guard let index = rows.firstIndex(where: { $0.id == selectedID }), rows.indices.contains(index + offset) else { return }
        selectedID = rows[index + offset].id
    }
}
