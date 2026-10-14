import AppKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor struct PeekSizingTests {
    init() { ZeusFonts.registerBundled() }
    @Test func renderedPeekFitsWindowAcrossLinesFontsTitlesOptionsAndTailEdges() throws {
        #expect(ZeusFonts.registerBundled())
        for font in ZeusFontChoice.allCases {
            for lines in [1, 3, 6, 10] {
                for hasTitle in [false, true] {
                    for hasOptions in [false, true] {
                        let card = Card(kind: hasOptions ? .question : .message,
                            title: hasTitle ? "Review **the** draft" : nil,
                            body: (1...lines).map { "Line \($0): **gold** text" }.joined(separator: "\n"),
                            options: hasOptions ? [CardOption(id: "yes", label: "Yes"), CardOption(id: "no", label: "No")] : [],
                            input: hasOptions ? InputSpec() : nil)
                        let layout = PeekLayout.measure(card: card, font: font, moreCount: 2, error: nil,
                            answeredOptionID: nil, available: CGSize(width: 800, height: 600))
                        #expect(layout.bodyLines == 6)
                        #expect(layout.showsMore == (lines > 6))
                        for edge in [ZeusDialogTail.Edge.top, .bottom, .leading, .trailing] {
                            let placement = PeekPlacement.place(art: CGRect(x: 340, y: 60, width: 120, height: 120),
                                anchorX: 400, contentSize: layout.contentSize, screen: CGRect(x: 0, y: 0, width: 800, height: 600))
                            let vertical = edge == .top || edge == .bottom
                            let size = CGSize(width: layout.contentSize.width + (vertical ? 0 : ZeusDialogTail.height),
                                height: layout.contentSize.height + (vertical ? ZeusDialogTail.height : 0))
                            #expect(placement.frame.height >= layout.contentSize.height)
                            for fraction in [0.0, 0.5, 1.0] {
                                let host = NSHostingView(rootView: PeekContent(card: card, layout: layout, moreCount: 2,
                                    error: nil, answeredOptionID: nil, tail: ZeusDialogTail(edge: edge, offset: 40), reveal: .fraction(fraction))
                                    .environment(\.zeusFontChoice, font).environment(\.zeusAnimationsActive, true))
                                let window = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                                window.isReleasedWhenClosed = false
                                window.contentView = host
                                host.layoutSubtreeIfNeeded()
                                #expect(host.fittingSize.width <= host.bounds.width + 0.01)
                                #expect(host.fittingSize.height <= host.bounds.height + 0.01)
                                window.close()
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func feedbackMessageReservesAllThreeLinesBeforeTypingStartsInBothFonts() {
        for font in ZeusFontChoice.allCases {
            let card = Card(kind: .message, body: "Still good. Quiet morning, nothing waiting on you. Anything you'd like me to pick up?")
            let layout = PeekLayout.measure(card: card, font: font, moreCount: 0, error: nil,
                answeredOptionID: nil, available: CGSize(width: 800, height: 600))
            #expect(!layout.showsMore)
            let first = fitting(card: card, layout: layout, font: font, reveal: .fraction(0))
            let final = fitting(card: card, layout: layout, font: font, reveal: .full)
            #expect(first == final)
            #expect(final.height <= layout.contentSize.height + ZeusDialogTail.height)
            #expect(final.width <= layout.contentSize.width)
        }
    }

    @Test func narrowedScreenRemeasuresWrapsButtonsAndIncludesErrorsAttachmentsAndReceipt() {
        for font in ZeusFontChoice.allCases {
            let card = Card(kind: .question, title: "A long title that has to truncate gracefully",
                body: String(repeating: "A message with **bold**, `code`, and wrapped words. ", count: 20),
                options: [CardOption(id: "yes", label: "Keep the draft"), CardOption(id: "no", label: "Revise the draft"), CardOption(id: "later", label: "Later")],
                input: InputSpec(), attachments: [Attachment(kind: .url, label: "Draft", target: "https://example.com")])
            let wide = PeekLayout.measure(card: card, font: font, moreCount: 12, error: nil,
                answeredOptionID: nil, available: CGSize(width: 800, height: 600))
            let smallScreen = CGRect(x: -240, y: 0, width: 240, height: 500)
            let layout = PeekLayout.measure(card: card, font: font, moreCount: 12,
                error: "Could not save your reply. Try again.", answeredOptionID: "yes", available: smallScreen.insetBy(dx: 8, dy: 8).size)
            #expect(layout.width < wide.width)
            #expect(layout.showsMore)
            let placement = PeekPlacement.place(art: CGRect(x: -180, y: 40, width: 80, height: 100), anchorX: -140,
                contentSize: layout.contentSize, screen: smallScreen)
            #expect(smallScreen.insetBy(dx: 8, dy: 8).contains(placement.frame))
            let host = NSHostingView(rootView: PeekContent(card: card, layout: layout, moreCount: 12,
                error: "Could not save your reply. Try again.", answeredOptionID: "yes", tail: placement.tail, reveal: .full)
                .environment(\.zeusFontChoice, font))
            #expect(host.fittingSize.width <= placement.frame.width)
            #expect(host.fittingSize.height <= placement.frame.height)
        }
    }

    @Test func fontChangeUsesFreshRenderedMetricsAndMoreExpandsTheCurrentCard() throws {
        let card = Card(kind: .message, body: (1...10).map { "Line \($0)" }.joined(separator: "\n"))
        let sizes = ZeusFontChoice.allCases.map { font in
            PeekLayout.measure(card: card, font: font, moreCount: 0, error: nil,
                answeredOptionID: nil, available: CGSize(width: 800, height: 600)).contentSize
        }
        #expect(sizes[0].height != sizes[1].height)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-peek-sizing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let peek = PeekModel(store: store)
        store.add(card)
        #expect(peek.receive(card, suppression: .init(), reduceMotion: false, typewriter: true))
        // The body overflow's More action uses .message; +N more alone uses .more.
        #expect(peek.expand(.message) == .init(cardID: card.id, reply: false))
        #expect(store.seenIDs.contains(card.id))
    }

    private func fitting(card: Card, layout: PeekLayout, font: ZeusFontChoice, reveal: ZeusPeekBubble.Reveal) -> CGSize {
        NSHostingView(rootView: PeekContent(card: card, layout: layout, moreCount: 0, error: nil,
            answeredOptionID: nil, tail: ZeusDialogTail(edge: .bottom, offset: 100), reveal: reveal)
            .environment(\.zeusFontChoice, font).environment(\.zeusAnimationsActive, true)).fittingSize
    }
}
