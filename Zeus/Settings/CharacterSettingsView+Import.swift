import Foundation
import ZeusSprites

/// Settings › Character's Import Character…, Open Example and Open Characters Folder (C1), on the shared
/// `LibraryImportModel`.
extension LibraryImportModel {
    static func characters(_ settings: AppSettings) -> LibraryImportModel {
        LibraryImportModel(kind: Kind(
            importTitle: "Import Character…", folderTitle: "Open Characters Folder",
            panelMessage: "Choose a character file (.json).",
            directory: { [weak settings] in settings?.userCharacterDirectory },
            plan: { [weak settings] data, source, directory in
                let builtIn = CharacterLibrary.load(userDirectory: nil).characters
                switch CharacterImport.plan(data: data, source: source, userDirectory: directory, builtIn: builtIn) {
                case .failure(let failure): return .failure(LineFailure(lines: failure.lines))
                case .success(let plan):
                    let id = plan.character.id
                    return .success(Plan(prompt: plan.conflict.map(CharacterImport.replacePrompt), done: CharacterImport.doneMessage(plan),
                                         notes: plan.warnings.map(\.plainMessage),
                                         install: { try CharacterImport.install(plan, into: $0) },
                                         select: { settings?.currentCharacterID = id }))
                }
            },
            writeExample: { try CharacterExample.write(into: $0) },
            reload: { [weak settings] in settings?.reloadCharacters() }
        ))
    }
}

extension AppSettings {
    /// Problems in character files as Settings lists them: one line per file that didn't load, with every reason,
    /// then warnings for files that did. Plain words, never silently skipped.
    var characterProblemLines: [(text: String, isError: Bool)] {
        let errors = Dictionary(grouping: characterProblems.filter { $0.severity == .error }, by: \.source)
        let failed = errors.keys.sorted().map { file in
            (text: "\(file) wasn't loaded. " + (errors[file] ?? []).map(\.plainMessage).joined(separator: " "), isError: true)
        }
        let warnings = characterProblems.filter { $0.severity == .warning && errors[$0.source] == nil }
            .map { (text: "\($0.source): \($0.plainMessage)", isError: false) }
        return failed + warnings
    }
}
