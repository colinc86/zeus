import AppKit
import Carbon
import Testing
@testable import Zeus

@MainActor struct LM2BShortcutTests {
    @Test func contextShortcutIsDistinctAndNeverChangesTheUsersStoredChoice() {
        let talk = TalkHotKey()
        let context = talk.askAboutThis
        #expect(context?.keyCode == talk.keyCode && context?.shift == true)
        #expect(context?.command == true && context?.option == true)
        #expect(talk.shift == false)
        var shifted = talk; shifted.shift = true
        #expect(shifted.askAboutThis == nil)
        var disabled = talk; disabled.enabled = false
        #expect(disabled.askAboutThis == nil)
        #expect(TalkHotKey(keyCode: UInt32.max).askAboutThis == nil)
        let function = TalkHotKey(keyCode: UInt32(kVK_F5), command: false, option: false)
        #expect(function.askAboutThis?.displayName == "⇧F5")
    }
    @Test func captionsExplainTheDerivedShortcutAndShiftedFallback() {
        let normal = GeneralSettingsView.shortcutCaption(TalkHotKey())
        #expect(normal.contains("⌥⌘Z opens Talk to Zeus from any app."))
        #expect(normal.contains("Add ⇧ (⌥⇧⌘Z) to ask about the window in front."))
        var shifted = TalkHotKey(); shifted.shift = true
        #expect(GeneralSettingsView.shortcutCaption(shifted).hasSuffix("Ask About This is in the Zeus menu, because your shortcut already uses ⇧."))
        shifted.enabled = false
        #expect(!GeneralSettingsView.shortcutCaption(shifted).contains("Ask About This"))
    }
    @Test func stoppedOrSuspendedRegistrarsCannotRetainAContextShortcut() {
        let registrar = GlobalHotKey()
        registrar.suspend(); #expect(!registrar.isContextRegistered)
        registrar.stop(); registrar.configure(TalkHotKey())
        #expect(!registrar.isContextRegistered && !registrar.isRegistered)
        #expect(registrar.contextError == nil)
    }
}
