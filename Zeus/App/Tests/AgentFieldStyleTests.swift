import AppKit
import Foundation
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

@MainActor private struct NoFieldCredentials: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}

@MainActor private func fieldImage<V: View>(_ content: V, font: ZeusFontChoice, scheme: ColorScheme = .light) throws -> CGImage {
    ZeusFonts.registerBundled()
    let view = NSHostingView(rootView: AnyView(content.environment(\.zeusFontChoice, font)
        .environment(\.colorScheme, scheme)
        .frame(width: 360, height: 72)))
    view.frame = CGRect(x: 0, y: 0, width: 360, height: 72)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return try #require(bitmap.cgImage)
}

@MainActor struct AgentFieldStyleTests {
    @Test(arguments: [(ZeusFontChoice.pixel, ColorScheme.light), (.pixel, .dark), (.system, .light), (.system, .dark)], ["", "fixture-only"])
    func passwordSlotUsesSecureZeusPlaceholderForBothSchemes(style: (ZeusFontChoice, ColorScheme), password: String) throws {
        let (font, scheme) = style
        let actual = try fieldImage(OpenCodePasswordField(password: .constant(password), save: {}), font: font, scheme: scheme)
        let reference = try fieldImage(ZeusTextField("OpenCode server password", text: .constant(password), secure: true), font: font, scheme: scheme)
        let stock = try fieldImage(SecureField("OpenCode server password", text: .constant(password)), font: font, scheme: scheme)
        let bytes = try #require(actual.dataProvider?.data) as Data
        #expect(bytes == (try #require(reference.dataProvider?.data) as Data))
        #expect(bytes != (try #require(stock.dataProvider?.data) as Data))
    }
    @Test(arguments: [ZeusFontChoice.pixel, .system])
    func serverURLLabelRemainsVisibleWhenTheFieldIsFilled(font: ZeusFontChoice) throws {
        let suite = "zeus-server-field-label-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: NoFieldCredentials())
        settings.openCodeURLText = ""
        let empty = try fieldImage(OpenCodeServerField(settings: settings), font: font)
        settings.openCodeURLText = "http://127.0.0.1:4096"
        let filled = try fieldImage(OpenCodeServerField(settings: settings), font: font)
        let unlabeled = try fieldImage(ZeusTextField("OpenCode server URL", text: .constant(settings.openCodeURLText)), font: font)
        let unlabeledEmpty = try fieldImage(ZeusTextField("OpenCode server URL", text: .constant("")), font: font)
        // Compare complete synthetic views: the label must add visible content in both states.
        // Native cache images can have flipped storage coordinates, so do not guess a crop band.
        #expect((try #require(empty.dataProvider?.data) as Data) != (try #require(unlabeledEmpty.dataProvider?.data) as Data))
        #expect((try #require(filled.dataProvider?.data) as Data) != (try #require(unlabeled.dataProvider?.data) as Data))
    }

    @Test(arguments: [ZeusFontChoice.pixel, .system], [false, true])
    func paneFieldKeepsZeusChromeForBothFontsAndConnectionStates(font: ZeusFontChoice, connected: Bool) throws {
        let suite = "zeus-pane-field-style-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: NoFieldCredentials())
        let socket = connected ? "/tmp/unused-field-\(UUID()).sock" : nil
        settings.setTmuxTarget(connected ? "%0" : nil, socketPath: socket)
        let actual = try fieldImage(TmuxTargetField(settings: settings, socketPath: socket), font: font)
        let expected = try fieldImage(ZeusTextField("Or type a tmux pane, such as %3", text: .constant(connected ? "%0" : "")).disabled(!connected), font: font)
        let stock = try fieldImage(TextField("Or type a tmux pane, such as %3", text: .constant(connected ? "%0" : "")).textFieldStyle(.roundedBorder).disabled(!connected), font: font)
        let actualData = try #require(actual.dataProvider?.data) as Data
        #expect(actualData == (try #require(expected.dataProvider?.data) as Data))
        #expect(actualData != (try #require(stock.dataProvider?.data) as Data))
    }
}
