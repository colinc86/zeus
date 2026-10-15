import SwiftUI

/// A persistent Privacy warning, including while all capture switches are off.
struct LearningStorageWarningView: View {
    let warnings: [String]
    var body: some View {
        ForEach(warnings, id: \.self) { warning in
            Text(warning).settingsError().fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(warning)
        }
    }
}
