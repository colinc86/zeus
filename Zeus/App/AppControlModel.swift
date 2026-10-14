import AppKit
import ZeusDesign

@MainActor protocol AppControlSurface: AnyObject {
    var controlAvatarFrame: CGRect { get }
    var controlScreens: [AppControlScreen] { get }
    var controlComposerFocused: Bool { get }
    var controlPanelOpen: Bool { get }
    func controlMoveAvatar(to origin: CGPoint)
    func controlRefreshVisibility()
}

/// Validates complete requests before changing settings. Runtime owns session scoping and authority rules.
@MainActor final class AppControlModel: AppControlling {
    private let settings: AppSettings
    private let visibility: AvatarVisibilityModel
    private let updater: any AppUpdating
    private weak var surface: (any AppControlSurface)?
    private let activeWindow: @MainActor () -> CGRect?
    private let idleSeconds: () -> Double
    private let info: [String: Any]
    private let formats: [String: String]

    init(settings: AppSettings, visibility: AvatarVisibilityModel, updater: any AppUpdating, surface: any AppControlSurface,
         activeWindow: @escaping @MainActor () -> CGRect? = AppControlPlacement.frontmostWindow,
         idleSeconds: @escaping () -> Double = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max) ?? .null) },
         info: [String: Any] = Bundle.main.infoDictionary ?? [:], formats: [String: String] = AppControlModel.formatPaths()) {
        self.settings = settings; self.visibility = visibility; self.updater = updater; self.surface = surface
        self.activeWindow = activeWindow; self.idleSeconds = idleSeconds; self.info = info; self.formats = formats
    }

    static func formatPaths() -> [String: String] {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { repo.deleteLastPathComponent() }
        return Dictionary(uniqueKeysWithValues: [("character", "SPRITE_FORMAT"), ("theme", "THEME_FORMAT")].map { key, name in
            let url = Bundle.main.url(forResource: name, withExtension: "md")
                ?? Bundle.main.url(forResource: name, withExtension: "md", subdirectory: "Formats")
                ?? repo.appendingPathComponent("docs/design/\(name).md")
            return (key, url.path)
        })
    }

    var assistantMayControlApp: Bool { settings.assistantMayControlApp }
    var assistantMayInstallUpdates: Bool { settings.assistantMayInstallUpdates }
    var appControlState: AppControlState {
        visibility.tick()
        let screens = surface?.controlScreens ?? []
        let frame = surface?.controlAvatarFrame ?? .zero
        let chosen = PanelPlacement.screen(for: frame, in: screens.map(\.frame))
        let index = screens.firstIndex { $0.frame == chosen } ?? 0
        let origin = screens.indices.contains(index) ? screens[index].frame.origin : .zero
        let idle = idleSeconds()
        return AppControlState(version: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown", updateAvailable: updater.availableVersion,
            characterID: settings.currentCharacterID, themeID: settings.currentThemeID, size: settings.avatarSize.rawValue,
            screen: index, position: ["x": Double(frame.minX - origin.x), "y": Double(frame.minY - origin.y)],
            screens: screens.map { ["width": Double($0.frame.width), "height": Double($0.frame.height), "scale": Double($0.scale)] },
            panelOpen: surface?.controlPanelOpen ?? false, hidden: visibility.isHidden, hiddenUntil: visibility.hiddenUntil,
            quietHoursActive: settings.isQuiet(at: Date()), ghostMode: settings.fadeZeusWhenIdle,
            userIdleSeconds: idle.isFinite ? max(0, idle) : 0, formats: formats)
    }

    private func requireControl() throws {
        guard assistantMayControlApp else { throw AppControlError.disabled(setting: "Let my assistant control Zeus") }
    }
    func setCharacter(id: String) throws -> AppChange {
        try requireControl()
        guard let character = settings.availableCharacters.first(where: { $0.id == id }) else { throw AppControlError.unknownID(id) }
        let previous = settings.currentCharacterID, settings = settings
        settings.currentCharacterID = id
        return AppChange(summary: "Switched to \(character.name)", undoTitle: "Undo", undo: { settings.currentCharacterID = previous })
    }
    func setTheme(id: String) throws -> AppChange {
        try requireControl()
        guard let theme = settings.availableThemes.first(where: { $0.id == id }) else { throw AppControlError.unknownID(id) }
        let previous = settings.currentThemeID, settings = settings
        settings.setTheme(id: id)
        return AppChange(summary: "Switched to \(theme.name)", undoTitle: "Undo", undo: { settings.setTheme(id: previous) })
    }
    private func create(name: String, json: Data, importer: LibraryImportModel) throws {
        guard let directory = importer.kind.directory() else { throw AppControlError.invalidArgument("The user library folder is unavailable.") }
        let source = name.hasSuffix(".json") ? name : name + ".json"
        let plan: LibraryImportModel.Plan
        switch importer.kind.plan(json, source, directory) {
        case .failure(let failure): throw AppControlError.invalidFile(failure.lines.joined(separator: "\n"))
        case .success(let valid): plan = valid
        }
        // Creating must not overwrite someone's character/theme. Import's replace flow remains user-owned.
        if let prompt = plan.prompt { throw AppControlError.invalidArgument(prompt + " Choose a new id to keep the existing file.") }
        do { try plan.install(directory) } catch {
            throw AppControlError.invalidFile("Zeus couldn't save it in your \(directory.lastPathComponent) folder. \(error.localizedDescription)")
        }
        importer.kind.reload(); plan.select()
    }
    func createCharacter(name: String, json: Data) throws -> AppChange {
        try requireControl()
        let previous = settings.currentCharacterID, settings = settings
        try create(name: name, json: json, importer: .characters(settings))
        return AppChange(summary: "Added \(settings.currentCharacter?.name ?? name)", undoTitle: "Undo", undo: { settings.currentCharacterID = previous })
    }
    func createTheme(name: String, json: Data) throws -> AppChange {
        try requireControl()
        let previous = settings.currentThemeID, settings = settings
        try create(name: name, json: json, importer: .themes(settings))
        return AppChange(summary: "Added \(settings.currentTheme.name)", undoTitle: "Undo", undo: { settings.setTheme(id: previous) })
    }
    func move(to placement: AvatarPlacement) throws -> AppChange {
        try requireControl()
        guard let surface else { throw AppControlError.invalidArgument("The avatar is unavailable.") }
        guard !surface.controlComposerFocused else { throw AppControlError.invalidArgument("the user is typing") }
        let previous = surface.controlAvatarFrame.origin
        let origin = try AppControlPlacement.origin(for: placement, avatar: surface.controlAvatarFrame, screens: surface.controlScreens, activeWindow: activeWindow())
        surface.controlMoveAvatar(to: origin)
        return AppChange(summary: "Moved Zeus", undoTitle: "Undo", undo: { [weak surface] in surface?.controlMoveAvatar(to: previous) })
    }
    func setSize(_ size: AvatarSize) throws -> AppChange {
        try requireControl()
        let previous = settings.avatarSize, settings = settings
        settings.avatarSize = size
        return AppChange(summary: "Set Zeus size to \(size.rawValue)", undoTitle: "Undo", undo: { settings.avatarSize = previous })
    }
    func hide(minutes: Int?, untilTomorrow: Bool) throws -> AppChange {
        try requireControl()
        guard untilTomorrow ? minutes == nil : minutes.map({ (1...720).contains($0) }) == true else {
            throw AppControlError.invalidArgument("Choose 1–720 minutes or until tomorrow.")
        }
        visibility.hide(for: untilTomorrow ? .tomorrow : .minutes(minutes ?? 1))
        surface?.controlRefreshVisibility()
        let visibility = visibility
        return AppChange(summary: untilTomorrow ? "Zeus hidden until tomorrow" : "Zeus hidden for \(minutes ?? 1) \(minutes == 1 ? "minute" : "minutes")",
                         undoTitle: "Show now", undo: { [weak surface] in visibility.show(); surface?.controlRefreshVisibility() })
    }
    func setAppearance(_ patch: AppearancePatch) throws -> AppChange {
        try requireControl()
        if let name = patch.font, ZeusFontChoice(rawValue: name) == nil { throw AppControlError.invalidArgument("Unknown font: \(name).") }
        if let name = patch.popupSoundName, PopupSound(rawValue: name) == nil { throw AppControlError.invalidArgument("Unknown pop-up sound: \(name).") }
        for value in [patch.ghostOpacity, patch.ghostDelaySeconds, patch.panelWidth].compactMap({ $0 }) where !value.isFinite {
            throw AppControlError.invalidArgument("Appearance numbers must be finite.")
        }
        for hour in [patch.quietStartHour, patch.quietEndHour].compactMap({ $0 }) where !(0...23).contains(hour) {
            throw AppControlError.invalidArgument("Quiet hours must be between 0 and 23.")
        }
        let old = AppearancePatch(ghostMode: patch.ghostMode.map { _ in settings.fadeZeusWhenIdle },
            ghostOpacity: patch.ghostOpacity.map { _ in settings.idleOpacity }, ghostDelaySeconds: patch.ghostDelaySeconds.map { _ in settings.idleFadeDelay },
            popupSound: patch.popupSound.map { _ in settings.popupSoundEnabled }, popupSoundName: patch.popupSoundName.map { _ in settings.popupSound.rawValue },
            font: patch.font.map { _ in settings.fontChoice.rawValue }, panelWidth: patch.panelWidth.map { _ in settings.conversationWidth },
            quietHours: patch.quietHours.map { _ in settings.quietHoursEnabled }, quietStartHour: patch.quietStartHour.map { _ in settings.quietStartHour },
            quietEndHour: patch.quietEndHour.map { _ in settings.quietEndHour })
        Self.apply(patch, to: settings)
        let settings = settings
        return AppChange(summary: "Changed Zeus appearance", undoTitle: "Undo", undo: { Self.apply(old, to: settings) })
    }
    private static func apply(_ patch: AppearancePatch, to settings: AppSettings) {
        if let value = patch.ghostMode { settings.fadeZeusWhenIdle = value }
        if let value = patch.ghostOpacity { settings.idleOpacity = value }
        if let value = patch.ghostDelaySeconds { settings.idleFadeDelay = value }
        if let value = patch.popupSound { settings.popupSoundEnabled = value }
        if let value = patch.popupSoundName.flatMap(PopupSound.init(rawValue:)) { settings.popupSound = value }
        if let value = patch.font.flatMap(ZeusFontChoice.init(rawValue:)) { settings.fontChoice = value }
        if let value = patch.panelWidth { settings.conversationWidth = value }
        if let value = patch.quietHours { settings.quietHoursEnabled = value }
        if let value = patch.quietStartHour { settings.quietStartHour = value }
        if let value = patch.quietEndHour { settings.quietEndHour = value }
    }
    func checkForUpdates() async throws -> UpdateCheckResult { try requireControl(); return try await updater.checkForUpdateInformation() }
    func installUpdate(version: String) async throws {
        try requireControl()
        guard assistantMayInstallUpdates else { throw AppControlError.disabled(setting: "Let my assistant install updates") }
        try await updater.installUpdate(version: version)
    }
}
