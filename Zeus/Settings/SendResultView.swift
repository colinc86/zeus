import SwiftUI
import ZeusDesign

struct SendResultView: View {
    let result: MessageSendResult
    @Environment(\.zeusPalette) private var palette

    var body: some View {
        let (text, failed): (String, Bool) = switch result {
        case .delivered: ("Delivered to your assistant.", false)
        case .queued(let reason): (reason, false)
        case .failed(let reason): ("Not sent: \(reason)", true)
        }
        Text(text).zeusFont(.caption).foregroundStyle(failed ? palette.destructive : palette.secondaryText)
            .accessibilityLabel(text)
    }
}
