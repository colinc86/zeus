import SwiftUI
import Testing
@testable import ZeusDesign

/// D3-7: an empty Zeus field's placeholder is drawn in secondary text, never like a typed value.
@MainActor
struct ZeusTextFieldTests {
    @Test(arguments: [ZeusPalette.light, .dark, .lightHighContrast, .darkHighContrast])
    func placeholderUsesSecondaryText(_ palette: ZeusPalette) {
        #expect(ZeusTextField.promptColor(palette) == palette.secondaryText)
        #expect(ZeusTextField.promptColor(palette) != palette.text)
    }

    @Test func plainAndSecureFieldsRender() {
        for secure in [false, true] {
            let view = ZeusTextField("OpenCode server password", text: .constant(""), secure: secure).frame(width: 300)
            #expect(ImageRenderer(content: view).cgImage != nil, "secure: \(secure)")
        }
    }
}
