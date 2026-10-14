import AppKit
import Carbon
import Testing
@testable import Zeus

@MainActor private final class RecorderRegistration: ShortcutRegistering {
    var error: String?
    var suspended = false
    var attempts: [TalkHotKey] = []
    var refuses: UInt32?
    func suspend() { suspended = true }
    func resume(_ shortcut: TalkHotKey) {
        suspended = false; attempts.append(shortcut)
        error = shortcut.keyCode == refuses ? "That shortcut is taken by another app." : nil
    }
}
@MainActor struct ShortcutRecorderTests {
    private func event(_ code: Int, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)))
    }
    @Test func everyKeyClassHasAUniqueHardwareCodeAndMenuEquivalent() {
        #expect(Set(TalkHotKey.keys.map(\.code)).count == TalkHotKey.keys.count)
        for key in TalkHotKey.keys {
            let shortcut = TalkHotKey(keyCode: key.code, command: false, option: true)
            #expect(shortcut.isValid && shortcut.key == key.name && shortcut.menuKey == key.equivalent)
        }
        let examples: [(Int, String)] = [(kVK_ANSI_Z,"Z"),(kVK_ANSI_5,"5"),(kVK_F19,"F19"),(kVK_ANSI_Slash,"/"),
            (kVK_LeftArrow,"←"),(kVK_Space,"Space"),(kVK_Return,"↩"),(kVK_Tab,"⇥"),(kVK_Escape,"⎋"),
            (kVK_Delete,"⌫"),(kVK_ForwardDelete,"⌦"),(kVK_Home,"↖"),(kVK_End,"↘"),(kVK_PageUp,"⇞"),(kVK_PageDown,"⇟"),(kVK_ANSI_Keypad5,"Keypad 5")]
        for (code, label) in examples { #expect(TalkHotKey(keyCode: UInt32(code)).displayName == "⌥⌘" + label) }
        #expect(TalkHotKey(keyCode: UInt32(kVK_F5), command: false, option: false, control: true).displayName == "⌃F5")
        #expect(TalkHotKey(keyCode: UInt32(kVK_Space), option: false, shift: true).displayName == "⇧⌘Space")
    }
    @Test func legacyLettersDecodeWithoutChangingTheSavedShapeUntilEdited() throws {
        let data = Data(#"{"key":"K","command":false,"option":true,"control":true,"shift":false,"enabled":true}"#.utf8)
        var old = try JSONDecoder().decode(TalkHotKey.self, from: data)
        #expect(old.keyCode == UInt32(kVK_ANSI_K) && old.displayName == "⌃⌥K")
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        #expect(encoded["keyCode"] == nil && encoded["key"] as? String == "K")
        old.keyCode = UInt32(kVK_Space)
        let edited = try JSONEncoder().encode(old)
        #expect(try JSONDecoder().decode(TalkHotKey.self, from: edited) == old)
        #expect((try JSONSerialization.jsonObject(with: edited) as? [String: Any])?["keyCode"] as? UInt32 == UInt32(kVK_Space))
        #expect(TalkHotKey().displayName == "⌥⌘Z")
    }
    @Test func reservedKeysAndModifiersAreValidatedBeforeRegistration() {
        for code in [kVK_ANSI_Q,kVK_ANSI_W,kVK_ANSI_Comma,kVK_Tab] {
            #expect(!TalkHotKey(keyCode: UInt32(code), option: false).isValid)
        }
        for code in [kVK_ANSI_Z,kVK_Space,kVK_ANSI_Keypad5] {
            #expect(!TalkHotKey(keyCode: UInt32(code), command: false, option: false, shift: true).isValid)
        }
        for key in TalkHotKey.keys where key.function { #expect(TalkHotKey(keyCode: key.code, command: false, option: false).isValid) }
        #expect(!TalkHotKey(keyCode: UInt32.max).isValid)
    }
    @Test func captureCancelClearResetAndTakenShortcutNeverLoseTheOldBinding() throws {
        let registration = RecorderRegistration()
        var saved = TalkHotKey()
        let model = ShortcutRecorderModel(registration: registration, current: { saved }, save: { saved = $0 })
        var announcements: [String] = []; model.announce = { announcements.append($0) }
        model.start(); #expect(model.isRecording && registration.suspended)
        model.handle(try event(kVK_Escape)); #expect(!model.isRecording && saved == TalkHotKey() && registration.attempts.last == saved)
        model.start(); model.handle(try event(kVK_Space, [.control,.option,.numericPad,.capsLock]))
        #expect(saved.displayName == "⌃⌥Space" && !model.isRecording && model.error == nil)
        let previous = saved
        registration.refuses = UInt32(kVK_F5)
        model.start(); model.handle(try event(kVK_F5))
        #expect(saved == previous && registration.attempts.last == previous)
        #expect(model.error == "That shortcut is taken by another app.")
        model.start(); #expect(model.error == nil)
        model.handle(try event(kVK_ANSI_Q, [.command])); #expect(saved == previous && model.error != nil)
        model.start(); model.handle(try event(kVK_Delete)); #expect(!saved.enabled && model.value == "None")
        model.reset(); #expect(saved == TalkHotKey() && model.value == "⌥⌘Z")
        #expect(announcements.contains("Recording") && announcements.contains("⌃⌥Space"))
        model.start(); #expect(!model.handle(try event(kVK_Tab)) && !model.isRecording)
    }
    @Test func menuAndCaptionUseTheNonLetterEquivalent() throws {
        let suite = "zeus-kr1-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.talkHotKey = TalkHotKey(keyCode: UInt32(kVK_LeftArrow), command: false, option: true, control: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = ShellController(defaults: defaults, cards: CardStore(fileURL: root.appendingPathComponent("cards.json")), settings: settings)
        let item = try #require(shell.menuModel.sections.flatMap { $0 }.first { $0.id == "talk" })
        #expect(item.shortcut?.key == Character(UnicodeScalar(NSLeftArrowFunctionKey) ?? "\u{FFFD}"))
        #expect(item.shortcut?.appKitModifiers == [.option,.control])
        let native = try #require(shell.menuModel.makeNSMenu(perform: { _ in }).items.first { $0.identifier?.rawValue == "talk" })
        #expect(native.keyEquivalent == String(item.shortcut?.key ?? "?"))
        #expect(native.keyEquivalentModifierMask == [.option,.control])
        #expect(GeneralSettingsView.menuBarIconCaption(hotKey: settings.talkHotKey).contains("⌃⌥←"))
    }
}
