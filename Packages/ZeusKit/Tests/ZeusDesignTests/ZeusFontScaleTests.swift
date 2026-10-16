import Foundation
import Testing
@testable import ZeusDesign

struct ZeusFontScaleTests {
    @Test func presetsRoundTripAndKeepPixelTextOnItsGrid() throws {
        #expect(ZeusFontScale.allCases.map(\.displayName) == ["Small", "Default", "Large", "Larger"])
        for scale in ZeusFontScale.allCases {
            #expect(try JSONDecoder().decode(ZeusFontScale.self, from: JSONEncoder().encode(scale)) == scale)
            for role in ZeusTextRole.allCases {
                let size = role.size(for: .pixel, scale: scale)
                #expect(size >= 11)
                #expect(size.truncatingRemainder(dividingBy: ZeusTextRole.pixelGridStep) == 0)
            }
        }
    }
    @MainActor @Test func approvedRoleTableAndStripMetrics() {
        ZeusFonts.registerBundled()
        let pixel: [[CGFloat]] = [[11, 16.5, 22, 22], [11, 11, 16.5, 16.5], [11, 11, 11, 16.5], [11, 11, 16.5, 16.5], [11, 11, 11, 11]]
        let system: [[CGFloat]] = [[12, 14, 16.5, 19], [10.5, 12.5, 15, 17], [9.5, 11, 13, 15], [10, 12, 14, 16.5], [10, 10, 10, 10]]
        for (index, role) in ZeusTextRole.allCases.enumerated() {
            #expect(ZeusFontScale.allCases.map { role.size(for: .pixel, scale: $0) } == pixel[index])
            #expect(ZeusFontScale.allCases.map { role.size(for: .system, scale: $0) } == system[index])
        }
        for choice in ZeusFontChoice.allCases {
            #expect(ZeusStatusStrip.height(for: choice) == 24)
            #expect(ZeusStatusStrip.height(for: choice, scale: .larger) >= ZeusFonts.lineHeight(.caption, choice: choice, scale: .larger) + 4)
        }
    }
    @Test func defaultPreservesExistingSizesAndSystemStepsIncrease() {
        for role in ZeusTextRole.allCases {
            for choice in ZeusFontChoice.allCases {
                #expect(role.size(for: choice, scale: .default) == role.size(for: choice))
            }
            let sizes = ZeusFontScale.allCases.map { role.size(for: .system, scale: $0) }
            #expect(zip(sizes, sizes.dropFirst()).allSatisfy { role == .badge ? $0 == $1 : $0 < $1 })
            #expect(sizes.allSatisfy { $0.truncatingRemainder(dividingBy: 0.5) == 0 })
        }
    }
}
