import AppKit
import SwiftUI
import ZeusDesign

/// Ledger metadata is an index only; the exact sent JSON remains the authoritative record.
enum JournalAnswerDisplay {
    static func isAnswer(_ item: JournalItem) -> Bool { item.payload.value.details["kind"] == "journal_answer" }
    static func size(_ item: JournalItem) -> String {
        if isAnswer(item) { let count = item.payload.value.details["item_count"] ?? "0"; return "\(count) \(count == "1" ? "item" : "items")" }
        return "\((item.payload.value.text ?? "").split(whereSeparator: \.isWhitespace).count) words"
    }
    static func rawCaption(_ item: JournalItem) -> String? {
        let details = item.payload.value.details
        var parts: [String] = []
        if details["raw_screen"] == "not allowed" { parts.append("Asked for pictures; not allowed") }
        else if let count = Int(details["pictures"] ?? ""), count > 0 { parts.append("Includes \(count) \(count == 1 ? "picture" : "pictures")") }
        if details["raw_typing"] == "not allowed" { parts.append("Asked for words; not allowed") }
        else if details["includes_words"] == "true" { parts.append("Includes your words") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct JournalAnswerPayload: Decodable {
    struct Item: Decodable, Identifiable {
        struct Picture: Decodable { let mimeType: String; let data: String }
        let id: String
        let time: String
        let app: String?
        let kind: String
        let text: String
        let words: String?
        let picture: Picture?
    }
    let items: [Item]
    static func decode(_ item: JournalItem) -> Self? {
        guard let text = item.payload.value.text else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(text.utf8))
    }
}

/// Constructed only for an expanded ledger row. No journal/frame-store lookup can substitute a newer image.
struct JournalAnswerDetail: View {
    let item: JournalItem
    @State private var payload: JournalAnswerPayload?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let range = item.payload.value.details["range"] { Text(range).settingsCaption() }
            if let query = item.payload.value.details["query"], !query.isEmpty { Text("“\(query)”").settingsBody() }
            if let caption = JournalAnswerDisplay.rawCaption(item) { Text(caption).settingsCaption() }
            if let payload {
                ForEach(payload.items) { entry in
                    ZeusFieldChrome {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.text).settingsBody().textSelection(.enabled)
                            if let words = entry.words { Text(words).settingsBody().textSelection(.enabled) }
                            if let picture = entry.picture { JournalAnswerPicture(picture: picture) }
                        }
                    }
                }
            } else {
                ZeusFieldChrome { Text(item.payload.value.text ?? item.payload.value.description).settingsBody().textSelection(.enabled) }
            }
        }.onAppear { payload = JournalAnswerPayload.decode(item) }
    }
}

private struct JournalAnswerPicture: View {
    let picture: JournalAnswerPayload.Item.Picture
    @State private var showsDetail = false
    @Environment(\.zeusPalette) private var palette
    private var image: NSImage? {
        guard picture.mimeType == "image/jpeg", let data = Data(base64Encoded: picture.data) else { return nil }
        return NSImage(data: data)
    }
    var body: some View {
        if let image {
            KeyboardButton { showsDetail = true } label: {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 180, maxHeight: 110)
                    .overlay(Rectangle().stroke(palette.outline, lineWidth: 1))
            }.buttonStyle(.plain).accessibilityLabel("View the covered picture sent to your assistant")
                .sheet(isPresented: $showsDetail) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Picture sent to your assistant").settingsTitle()
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 700, maxHeight: 500)
                            .overlay(Rectangle().stroke(palette.outline, lineWidth: 1))
                        KeyboardButton("Done") { showsDetail = false }.keyboardShortcut(.cancelAction).accessibilityLabel("Close picture")
                    }.padding(24)
                }
        } else { Text("This sent picture can't be displayed.").settingsCaption() }
    }
}
