import AppKit
import SwiftUI
import ZeusDesign

struct JournalPictureRow: View {
    let picture: JournalPicture
    @Bindable var model: JournalPictureModel
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        KeyboardButton { model.selectedID = picture.id; model.confirmsDeleteBoth = false } label: {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let image = model.thumbnail(picture) { Image(nsImage: image).resizable().scaledToFit() }
                    else { Text("No picture").settingsCaption().frame(maxWidth: .infinity, maxHeight: .infinity).background(palette.field) }
                }.frame(width: 96, height: 60).overlay(Rectangle().strokeBorder(palette.outline, lineWidth: 1)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(picture.time.formatted(date: .omitted, time: .shortened)) · \(picture.app.map(JournalDisplay.appName) ?? "Zeus")").settingsCaption()
                    Text(JournalItemView.styled(picture.description, palette: palette)).settingsBody().fixedSize(horizontal: false, vertical: true)
                    Text(model.caption(picture)).settingsCaption()
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Picture of \(picture.app.map(JournalDisplay.appName) ?? "app"), \(picture.description)")
        .accessibilityHint("Open picture details")
        .contextMenu {
            Button("Delete Picture") { model.delete(picture, includingDescription: false) }.disabled(model.frame(picture) == nil)
            Button("Delete Both…") { model.selectedID = picture.id; model.confirmsDeleteBoth = true }
        }
        .accessibilityAction(named: "Delete Picture") { model.delete(picture, includingDescription: false) }
    }
}

struct JournalPictureDetail: View {
    @Bindable var model: JournalPictureModel
    @Environment(\.zeusPalette) private var palette
    @FocusState private var cancelFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let picture = model.selected {
                Text("Picture from \(picture.time.formatted(date: .omitted, time: .shortened))").settingsTitle()
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let frame = model.frame(picture)?.value {
                            CoveredPictureView(frame: frame).frame(width: 448, height: 280).overlay(Rectangle().strokeBorder(palette.outline, lineWidth: 1))
                            let covered = frame.boxes.filter { $0.kind == .text }.count
                            let blurred = frame.boxes.count - covered
                            HStack(spacing: 4) {
                                Rectangle().strokeBorder(palette.secondaryText, lineWidth: 1).frame(width: 10, height: 7).accessibilityHidden(true)
                                Text("Covered text ·").settingsCaption()
                                Rectangle().strokeBorder(palette.secondaryText, lineWidth: 1).frame(width: 10, height: 7).accessibilityHidden(true)
                                Text("Pixellated picture").settingsCaption()
                            }
                            Text(Self.counts(covered: covered, blurred: blurred)).settingsCaption()
                        } else {
                            Text("No picture").settingsCaption().frame(width: 448, height: 280).background(palette.field)
                            Text(model.caption(picture)).settingsCaption()
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        field("App", picture.app.map(JournalDisplay.appName) ?? "Zeus")
                        field("Window", picture.windowTitle)
                        field("Description", picture.description)
                        Text("Kept until \(picture.expiresAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))").settingsCaption()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.confirmsDeleteBoth {
                    Text("Delete this picture and its description? This can't be undone.").settingsBody()
                    HStack {
                        Spacer()
                        KeyboardButton("Cancel", focus: $cancelFocused) { model.confirmsDeleteBoth = false }.keyboardShortcut(.cancelAction)
                        KeyboardButton("Delete Both") { model.delete(picture, includingDescription: true) }.buttonStyle(ZeusButtonStyle(.destructive, size: .small))
                    }.onAppear { cancelFocused = true }
                } else {
                    HStack {
                        Text("← → previous and next picture").settingsCaption()
                        Spacer()
                        KeyboardButton("Delete Picture") { model.delete(picture, includingDescription: false) }
                            .keyboardShortcut(KeyEquivalent("\u{8}"), modifiers: .command).disabled(model.frame(picture) == nil)
                        KeyboardButton("Delete Both…") { model.confirmsDeleteBoth = true }
                        KeyboardButton("Close") { model.selectedID = nil }.keyboardShortcut(.cancelAction)
                            .buttonStyle(ZeusButtonStyle(.primary, size: .small))
                    }
                }
            }
            if model.deleted != nil {
                HStack { Text("Deleted.").settingsCaption(); KeyboardButton("Undo") { model.undoDelete() }.accessibilityLabel("Undo picture deletion") }
            }
            if let error = model.error { Text(error).settingsError() }
        }.padding(24).frame(width: 820).environment(\.zeusFontChoice, .system)
            .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
            .onKeyPress(.leftArrow) { guard !model.confirmsDeleteBoth else { return .ignored }; model.step(1); return .handled }
            .onKeyPress(.rightArrow) { guard !model.confirmsDeleteBoth else { return .ignored }; model.step(-1); return .handled }
    }
    static func counts(covered: Int, blurred: Int) -> String {
        [covered > 0 ? "\(covered) covered" : nil, blurred > 0 ? "\(blurred) pixellated" : nil].compactMap { $0 }.joined(separator: " · ")
    }
    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).settingsHeading()
            Text(JournalItemView.styled(value, palette: palette)).settingsBody().fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

struct CoveredPictureView: View {
    let frame: FrameItem
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        GeometryReader { geometry in
            let ratio = min(geometry.size.width / CGFloat(max(1, frame.width)), geometry.size.height / CGFloat(max(1, frame.height)))
            let width = CGFloat(frame.width) * ratio, height = CGFloat(frame.height) * ratio
            ZStack(alignment: .topLeading) {
                if let image = NSImage(data: frame.heic) { Image(nsImage: image).resizable().frame(width: width, height: height) }
                ForEach(Array(frame.boxes.enumerated()), id: \.offset) { _, box in
                    Rectangle().strokeBorder(palette.focusRing, lineWidth: 1)
                        .frame(width: box.width * width, height: box.height * height)
                        .offset(x: box.x * width, y: box.y * height)
                }
            }.frame(width: width, height: height).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Picture of \(frame.appName), \(frame.boxes.count) areas covered")
    }
}
