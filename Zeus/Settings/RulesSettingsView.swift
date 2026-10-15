import SwiftUI
import AppKit
import ZeusDesign

struct RulesSettingsView: View {
    @Bindable var model: RulesPaneModel
    @State private var showsEditor = false
    @State private var showsRetired = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rules").settingsTitle()
            SettingsSegments(label: "New rules", options: [(0.0, "Ask me first"), (0.5, "Balanced"), (1.0, "Just do it")],
                selection: Binding(get: { model.autonomy }, set: { model.autonomy = $0 }))
            Text(dialCaption).settingsCaption()
            SettingsDivider()
            ForEach([LearnedRuleStatus.active, .shadow, .proposed], id: \.self) { status in section(status) }
            let retired = model.rules.filter { $0.status == .retired }
            if !retired.isEmpty {
                KeyboardButton(showsRetired ? "Hide retired" : "Show \(retired.count) retired") { showsRetired.toggle() }
                    .accessibilityLabel(showsRetired ? "Hide retired rules" : "Show \(retired.count) retired rules")
                if showsRetired { section(.retired) }
            }
            KeyboardButton("Add Rule…") { model.beginEdit(nil); showsEditor = true }.accessibilityLabel("Add rule")
            if model.deletedRule != nil {
                HStack { Text("Deleted.").settingsCaption(); KeyboardButton("Undo") { model.undoDelete() }.accessibilityLabel("Undo rule deletion") }
            }
            if let error = model.error ?? model.store.lastError { Text(error).settingsError() }
        }
        .sheet(isPresented: $showsEditor) {
            RuleEditorView(model: model, cancel: { showsEditor = false }, saved: { showsEditor = false })
        }
        .onChange(of: model.selectedRuleID, initial: true) { _, id in
            if model.rules.first(where: { $0.id == id })?.status == .retired { showsRetired = true }
        }
    }
    private var dialCaption: String {
        if model.autonomy == 0 { return "Every new rule waits in Suggested until you turn it on." }
        if model.autonomy == 1 { return "Rules start at once. Rules that act for you still show what they'd have done the first time, then act without asking. Undo is always there." }
        return "Rules about timing and tone start at once. Rules that act for you show what they'd have done once, and wait for your OK."
    }
    @ViewBuilder private func section(_ status: LearnedRuleStatus) -> some View {
        let rules = model.rules.filter { $0.status == status }
        if status == .active || !rules.isEmpty {
            Text("\(title(status)) · \(rules.count)").settingsHeading()
            if status == .active && rules.isEmpty {
                Text("No rules yet. Zeus and your assistant suggest rules from what Zeus keeps, once a day. You can also add your own.").settingsCaption()
            }
            ForEach(rules) { rule in row(rule).id(rule.id) }
            SettingsDivider()
        }
    }
    private func title(_ status: LearnedRuleStatus) -> String {
        switch status { case .active: "Active"; case .shadow: "Waiting for your OK"; case .proposed: "Suggested"; case .retired: "Retired" }
    }
    private func row(_ rule: LearnedRule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(rule.sentence).settingsBody().lineLimit(2)
                Spacer()
                if rule.status == .active {
                    Toggle("", isOn: Binding(get: { rule.status == .active }, set: { model.setEnabled($0, rule: rule) }))
                        .labelsHidden().accessibilityLabel("Active rule: \(rule.sentence)")
                }
                actions(rule)
            }
            Text(RulesPaneModel.triggerText(rule.trigger, appName: JournalDisplay.appName)).settingsCaption()
            if rule.status == .shadow { Text(model.shadowCaption(rule)).settingsCaption() }
            HStack(spacing: 6) {
                if RulesPaneModel.alwaysAsks(rule) { Text("Always asks").settingsCaption() }
                else { RuleConfidence(confidence: rule.confidence) }
                Text("· \(rule.updatedBy == .agent ? "from your assistant" : rule.created == rule.updated ? "added by you" : "edited by you") · \(rule.updated.formatted(.relative(presentation: .named)))").settingsCaption()
            }
            HStack {
                switch rule.status {
                case .active: EmptyView()
                case .shadow:
                    KeyboardButton("OK") { model.approve(rule) }.accessibilityLabel("Approve: \(rule.sentence)")
                    KeyboardButton("Not This") { model.dismiss(rule) }.accessibilityLabel("Not this rule: \(rule.sentence)")
                case .proposed:
                    KeyboardButton("Turn On") { model.approve(rule) }.accessibilityLabel("Turn on: \(rule.sentence)")
                    KeyboardButton("Dismiss") { model.setEnabled(false, rule: rule) }.accessibilityLabel("Dismiss: \(rule.sentence)")
                case .retired:
                    KeyboardButton("Turn Back On") { model.approve(rule) }.accessibilityLabel("Turn back on: \(rule.sentence)")
                }
                Spacer()

            }
        }
        .popover(isPresented: Binding(get: { model.selectedRuleID == rule.id }, set: { if !$0 { model.selectedRuleID = nil } })) {
            RuleEvidenceView(model: model, rule: rule)
        }
    }
    private func actions(_ rule: LearnedRule) -> some View {
        Menu {
            Button("Why?") { model.selectedRuleID = rule.id }
            Button("Edit…") { model.beginEdit(rule); showsEditor = true }
            Button("Delete") { model.delete(rule) }
        } label: { Text("…") }.accessibilityLabel("Rule actions: \(rule.sentence)")
    }
}

struct RuleConfidence: View {
    let confidence: Double
    @Environment(\.zeusPalette) private var palette
    static func word(_ value: Double) -> String { value >= 0.75 ? "Sure" : value >= 0.45 ? "Fairly sure" : "Unsure" }
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1) {
            ForEach(0..<5) { cell in
                Rectangle().fill(cell < max(1, min(5, Int((confidence * 5).rounded()))) ? palette.focusRing : palette.fieldBorder)
                    .frame(width: 5, height: 9)
            }
            }
            Text(Self.word(confidence)).settingsCaption()
        }.accessibilityElement(children: .ignore).accessibilityLabel("Confidence: \(Self.word(confidence))")
    }
}

struct RuleEvidenceView: View {
    let model: RulesPaneModel
    let rule: LearnedRule
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("Why this rule").settingsTitle()
            let evidence = model.journal.evidence(ids: rule.evidence)
            ForEach(Array(evidence.prefix(5))) { JournalItemView(item: $0) }
            if evidence.count > 5 { Text("and \(evidence.count - 5) more").settingsCaption() }
            if evidence.count < rule.evidence.count { Text("Some of the reasons were deleted.").settingsCaption() }
            if evidence.isEmpty { Text("No stored evidence remains for this rule.").settingsCaption() }
            Text("\((rule.author ?? rule.updatedBy) == .agent ? "Proposed by your assistant" : "Added by you") on \(RulesPaneModel.dateText(rule.created, time: false))").settingsCaption()
            SettingsDivider()
            Text("What happened since").settingsHeading()
            let events = model.outcomes(for: rule)
            if events.isEmpty { Text("Nothing has happened with this rule yet.").settingsCaption() }
            ForEach(Array(events.prefix(10))) { event in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    RuleOutcomeGlyph(outcome: event.outcome).accessibilityHidden(true)
                    Text("\(RulesPaneModel.dateText(event.at)) · \(RulesPaneModel.outcomeLabel(event.outcome)) · \(RulesPaneModel.outcomeSource(event))").settingsCaption()
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(RulesPaneModel.dateText(event.at)), \(RulesPaneModel.outcomeLabel(event.outcome)), \(RulesPaneModel.outcomeSource(event))")
            }
            if events.count > 10 { Text("and \(events.count - 10) earlier").settingsCaption() }
            if RulesPaneModel.alwaysAsks(rule) { Text("Always asks · \(RuleConfidence.word(rule.confidence))").settingsCaption() }
            else { RuleConfidence(confidence: rule.confidence) }
        }.padding(20)
        }.frame(width: 440, height: min(560, max(320, (NSScreen.main?.visibleFrame.height ?? 800) - 100)))
            .environment(\.zeusFontChoice, .system)
    }
}

private struct RuleEditorView: View {
    @Bindable var model: RulesPaneModel
    let cancel: @MainActor @Sendable () -> Void
    let saved: @MainActor @Sendable () -> Void
    @FocusState private var cancelFocused: Bool
    private var chosenApps: [String] { model.appIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private var stateChoices: [ZeusChoice<String>] {
        var values = [ZeusChoice(id: "tests failing", title: "Tests failing"), ZeusChoice(id: "in a meeting", title: "In a meeting")]
        if !["", "tests failing", "in a meeting"].contains(model.state) { values.append(ZeusChoice(id: model.state, title: model.state)) }
        return values
    }
    private func chooseApp() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true); panel.message = "Choose an app for this rule."
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier, !chosenApps.contains(id) else { return }
                model.appIDs = (chosenApps + [id]).joined(separator: ", ")
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.editingID == nil ? "New Rule" : "Edit Rule").settingsTitle()
            ZeusTextField("Say what Zeus or your assistant should do", text: $model.sentence).accessibilityLabel("Rule")
            Text("When").settingsHeading()
            HStack {
                ForEach(1...7, id: \.self) { day in
                    let name = Calendar.current.shortWeekdaySymbols[day - 1]
                    Toggle(name, isOn: Binding(get: { model.weekdays.contains(day) }, set: { if $0 { model.weekdays.insert(day) } else { model.weekdays.remove(day) } }))
                        .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                }
            }
            HStack {
                ZeusTextField("Start HH:mm", text: $model.startMinute).accessibilityLabel("Rule start time")
                ZeusTextField("End HH:mm", text: $model.endMinute).accessibilityLabel("Rule end time")
            }
            Text("Leave times and days empty for any time.").settingsCaption()
            Text("Apps").settingsHeading()
            if chosenApps.isEmpty { Text("Any app").settingsCaption() }
            ForEach(chosenApps, id: \.self) { id in
                HStack {
                    Text(JournalDisplay.appName(id)).settingsBody(); Spacer()
                    KeyboardButton("Remove") { model.appIDs = chosenApps.filter { $0 != id }.joined(separator: ", ") }
                        .accessibilityLabel("Remove \(JournalDisplay.appName(id)) from rule")
                }
            }
            KeyboardButton("Choose App…", action: chooseApp).accessibilityLabel("Choose rule app")
            ZeusMenuPicker("State", choices: stateChoices,
                selection: Binding<String?>(get: { model.state.isEmpty ? nil : model.state }, set: { model.state = $0 ?? "" }), noneTitle: "Any")
            Text(model.kind == .passive ? "Changes only when and how Zeus talks to you" : "Acts for you outside Zeus").settingsBody()
            if model.editingID == nil { Text("To have your assistant act for you, ask it. It suggests a rule you can OK.").settingsCaption() }
            if let error = model.error { Text(error).settingsError() }
            HStack {
                Spacer()
                KeyboardButton("Cancel", focus: $cancelFocused, action: cancel).keyboardShortcut(.cancelAction).accessibilityLabel("Cancel rule edit")
                KeyboardButton("Save") { if model.save() { saved() } }.buttonStyle(ZeusButtonStyle(.primary, size: .small)).accessibilityLabel("Save rule")
            }
        }.padding(24).frame(width: 560).environment(\.zeusFontChoice, .system)
            .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).toggleStyle(ZeusCheckboxStyle())
            .onAppear { cancelFocused = true }
    }
}

/// Uses the existing pixel symbols and tiny drawn marks, avoiding unsupported font glyphs.
private struct RuleOutcomeGlyph: View {
    let outcome: RuleOutcome
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        Group {
            switch outcome {
            case .accepted: ZeusGlyph(.check)
            case .undone: ZeusGlyph(.reply)
            case .skipped: ZeusGlyph(.close)
            case .ignored, .stale: Rectangle().frame(width: 7, height: 1)
            case .toggledOff: Circle().stroke(lineWidth: 1).frame(width: 6, height: 6)
            case .toggledOn: Circle().frame(width: 6, height: 6)
            case .edited:
                Path { path in
                    for step in 0..<5 { path.addRect(CGRect(x: step + 1, y: 5 - step, width: 2, height: 2)) }
                    path.addRect(CGRect(x: 0, y: 7, width: 2, height: 1))
                }.frame(width: 7, height: 8)
            }
        }.foregroundStyle(palette.secondaryText).frame(width: 8)
    }
}
