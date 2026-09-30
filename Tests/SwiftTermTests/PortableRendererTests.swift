import Foundation
import Testing
@testable import SwiftTerm

struct PortableRendererTests {
    @Test func placeholdersFollowTheRequestedScrollbackViewport() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3, scrollback: 8)
        let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255]).base64EncodedString()
        terminal.feed(text: "\u{1b}_Ga=T,f=32,s=2,v=1,i=1,p=7,c=2,r=1,U=1,C=1;\(pixels)\u{1b}\\")
        terminal.feed(text: "\u{1b}[38;2;0;0;1m\u{1b}[58;2;0;0;7m\u{10EEEE}\u{10EEEE}\u{1b}[0m\r\nA\r\nB\r\nC")
        terminal.terminalLock.withLock {
            let snapshot = terminal.kittyGraphicsRenderSnapshot()
            #expect(terminal.visibleKittyPlaceholderPlacements(snapshot: snapshot,
                cellWidth: 10, cellHeight: 20).isEmpty)
            let crops = terminal.visibleKittyPlaceholderPlacements(snapshot: snapshot,
                cellWidth: 10, cellHeight: 20, topRow: 0, rowCount: 4)
            #expect(crops.count == 2)
            #expect(crops.allSatisfy { $0.destination.y == 5 })
            #expect(terminal.visibleKittyPlaceholderPlacements(snapshot: snapshot,
                cellWidth: 10, cellHeight: 20, topRow: Int.max, rowCount: Int.max).isEmpty)
            #expect(terminal.visibleKittyPlaceholderPlacements(snapshot: snapshot,
                cellWidth: 10, cellHeight: 20, rowCount: -1).isEmpty)
        }
    }

    @Test func selectionRangeMatchesTheTextThatIsCopied() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3)
        terminal.feed(text: "abcdef")
        let selection = SelectionService(terminal: terminal)
        terminal.terminalLock.withLock {
            selection.setSoftStart(row: 0, col: 1)
            selection.dragExtend(row: 0, col: 4)
            let range = selection.selectedColumnsRange(row: 0, cols: 8)
            #expect(range == 1..<4)
            #expect(selection.getSelectedText() == "bcd")
        }
    }

    @Test func lineSizingIsAvailableToPortableRenderers() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3)
        terminal.feed(text: "\u{1b}#6double\r\n\u{1b}#3top\r\n\u{1b}#4bottom")
        #expect(terminal.getLine(row: 0)?.renderMode == .doubleWidth)
        #expect(terminal.getLine(row: 1)?.renderMode == .doubledTop)
        #expect(terminal.getLine(row: 2)?.renderMode == .doubledDown)
    }

    @Test func equalZImagesSortByImageIDRegardlessOfTransmissionOrder() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3)
        let pixels = Data([255, 0, 0, 255]).base64EncodedString()
        for id in [9, 2, 5] {
            terminal.feed(text: "\u{1b}_Ga=T,f=32,s=1,v=1,i=\(id),C=1,z=-1;\(pixels)\u{1b}\\")
        }
        #expect(terminal.kittyGraphicsRenderSnapshot().placements.map(\.imageId) == [2, 5, 9])
    }
}
