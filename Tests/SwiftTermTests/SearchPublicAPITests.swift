import Foundation
import Testing

// Not @testable: this file only sees what a host outside the module can use.
import SwiftTerm

final class SearchPublicAPITests {
    private final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let delegate = Delegate()

    private func makeTerminal(cols: Int = 20, rows: Int = 4, scrollback: Int = 100) -> Terminal {
        Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
    }

    @Test func testFindAllReachesScrollback() {
        let terminal = makeTerminal()
        for i in 0..<20 {
            terminal.feed(text: "line \(i) needle\r\n")
        }
        let search = SearchService(terminal: terminal)
        let matches = terminal.terminalLock.withLock { search.findAll(term: "NEEDLE") }
        #expect(matches.count == 20)
        #expect(matches.first == SearchResult(term: "NEEDLE", col: 7, row: 0, size: 6))
        // Rows count from the top of the scrollback, as SelectionService does.
        #expect(matches.last?.row == 19)
    }

    @Test func testFindNextAndPreviousStepThroughMatches() {
        let terminal = makeTerminal()
        terminal.feed(text: "ab ab ab")
        let search = SearchService(terminal: terminal)
        terminal.terminalLock.withLock {
            #expect(search.findNext(term: "ab")?.col == 0)
            #expect(search.findNext(term: "ab")?.col == 3)
            #expect(search.findPrevious(term: "ab")?.col == 0)
            let range = search.selectionRange(for: search.lastResult!)
            #expect(range.start == Position(col: 0, row: 0))
            #expect(range.end == Position(col: 2, row: 0))
            search.updateLastSelection(SearchSelection(start: Position(col: 6, row: 0), end: Position(col: 8, row: 0)))
            #expect(search.findNext(term: "ab")?.col == 0)
        }
    }

    @Test func testInvalidateSeesNewOutput() {
        let terminal = makeTerminal()
        terminal.feed(text: "one\r\n")
        let search = SearchService(terminal: terminal)
        #expect(terminal.terminalLock.withLock { search.findAll(term: "two") }.isEmpty)
        terminal.feed(text: "two\r\n")
        terminal.terminalLock.withLock {
            search.invalidate()
            #expect(search.findAll(term: "two").count == 1)
        }
    }
}
