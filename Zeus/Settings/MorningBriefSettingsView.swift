import SwiftUI
import ZeusDesign

struct MorningBriefSettingsView: View {
    @Bindable var settings: MorningBriefSettings
    let managed: Bool
    private var selection: Binding<MorningBriefSchedule?> {
        Binding(get: { settings.schedule }, set: { if let value = $0 { settings.schedule = value } })
    }
    private var time: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: Date()) ?? Date()
        }, set: {
            let components = Calendar.current.dateComponents([.hour, .minute], from: $0)
            settings.hour = components.hour ?? 8; settings.minute = components.minute ?? 0
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Morning brief").settingsTitle()
            Toggle("Ask my assistant for a morning brief", isOn: Binding(
                get: { settings.effectiveEnabled(managed: managed) }, set: { settings.enabled = $0 }))
                .toggleStyle(ZeusCheckboxStyle()).accessibilityLabel("Ask my assistant for a morning brief")
            Text("At the start of your day, Zeus asks your assistant for one short brief of what matters today: what's coming up, what's at risk, what it has prepared. It uses yesterday's summary when Learn from me is on, its own notes and tools, and nothing else. Rate it like any message.")
                .settingsCaption()
            VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xs) {
                Text("When").settingsHeading()
                ZeusChoiceList([.init(id: MorningBriefSchedule.firstActivity, title: "After my first activity",
                                     detail: "When you start using the Mac, within the first hour of the day.")], selection: selection)
                HStack {
                    ZeusChoiceList([.init(id: MorningBriefSchedule.fixedTime, title: "At a fixed time")], selection: selection)
                    ZeusFieldChrome {
                        DatePicker("Brief time", selection: time, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.field).labelsHidden().font(.system(size: 13))
                            .accessibilityLabel("Brief time")
                    }.fixedSize().disabled(settings.schedule != .fixedTime)
                }
            }.disabled(!settings.effectiveEnabled(managed: managed))
        }
    }
}
