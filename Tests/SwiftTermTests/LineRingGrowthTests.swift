//
//  LineRingGrowthTests.swift
//
//  The line ring allocates its slots as lines arrive instead of reserving one
//  per line of scrollback up front. These tests check that growing never
//  changes which line is where: while the ring grows, as it starts to wrap,
//  and across the operations that change its length or rearrange it.
//

import Foundation
import Testing

@testable import SwiftTerm

@Suite final class LineRingGrowthTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    private func makeTerminal(cols: Int = 20, rows: Int = 5, scrollback: Int) -> Terminal {
        Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
    }

    private func text(_ terminal: Terminal, _ row: Int) -> String {
        terminal.buffer.translateBufferLineToString(lineIndex: row, trimRight: true)
    }

    /// Writes numbered lines `first..<end`, each ending in a newline.
    private func feedNumbered(_ terminal: Terminal, _ range: Range<Int>) {
        var output = ""
        for i in range { output += "line \(i)\r\n" }
        terminal.feed(text: output)
    }

    /// Every line from the top of the buffer holds the expected number, in order.
    private func expectNumbered(_ terminal: Terminal, through last: Int,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        let buffer = terminal.buffer
        // The cursor sits on the empty line after the last one written.
        let written = buffer.yBase + buffer.y
        for row in 0..<written {
            let expected = "line \(last - written + 1 + row)"
            #expect(text(terminal, row) == expected, "row \(row)", sourceLocation: sourceLocation)
        }
    }

    @Test func aNewTerminalDoesNotReserveItsWholeScrollback() {
        let terminal = makeTerminal(scrollback: 10_000)
        let lines = terminal.buffer.lines
        #expect(lines.maxLength == 10_005)
        #expect(lines.capacity == CircularBufferLineList.initialCapacity)
    }

    @Test func growingKeepsLinesInOrder() {
        let terminal = makeTerminal(scrollback: 1_000)
        var written = 0
        for chunk in [10, 50, 3, 200, 137, 400] {
            feedNumbered(terminal, written..<(written + chunk))
            written += chunk
            let lines = terminal.buffer.lines
            #expect(lines.capacity >= lines.count)
            #expect(lines.capacity <= lines.maxLength)
            expectNumbered(terminal, through: written - 1)
        }
    }

    @Test func theRingWrapsOnlyOnceItReachesItsLimit() {
        let terminal = makeTerminal(scrollback: 300)
        feedNumbered(terminal, 0..<2_000)
        let lines = terminal.buffer.lines
        #expect(lines.capacity == lines.maxLength)
        #expect(lines.isFull)
        expectNumbered(terminal, through: 1_999)
        #expect(terminal.buffer.totalLinesTrimmed == 2_000 - (300 + 5) + 1)
    }

    @Test func changingTheHistoryLimitKeepsTheNewestLines() {
        let terminal = makeTerminal(scrollback: 500)
        feedNumbered(terminal, 0..<300)
        terminal.changeHistorySize(100)
        expectNumbered(terminal, through: 299)
        #expect(terminal.buffer.lines.capacity <= terminal.buffer.lines.maxLength)
        terminal.changeHistorySize(5_000)
        feedNumbered(terminal, 300..<1_500)
        expectNumbered(terminal, through: 1_499)
        #expect(terminal.buffer.lines.capacity < terminal.buffer.lines.maxLength)
    }

    @Test func resizingAGrowingRingKeepsItsContent() {
        let terminal = makeTerminal(cols: 30, rows: 8, scrollback: 400)
        feedNumbered(terminal, 0..<90)
        for (cols, rows) in [(12, 4), (40, 20), (30, 8)] {
            terminal.resize(cols: cols, rows: rows)
            let buffer = terminal.buffer
            let all = (0..<(buffer.yBase + buffer.y)).map { text(terminal, $0) }.joined()
            // Reflow may split or join rows; the text itself must survive in order.
            #expect(all.hasSuffix("line 88line 89"))
            #expect(buffer.lines.capacity >= buffer.lines.count)
        }
    }

    @Test func aResetGivesBackTheSlots() {
        let terminal = makeTerminal(scrollback: 5_000)
        feedNumbered(terminal, 0..<3_000)
        #expect(terminal.buffer.lines.capacity > 3_000)
        terminal.feed(text: "\u{1b}c")
        #expect(terminal.buffer.lines.capacity == CircularBufferLineList.initialCapacity)
        feedNumbered(terminal, 0..<100)
        expectNumbered(terminal, through: 99)
    }

    @Test func growingAfterTheStartHasMovedKeepsOrder() {
        // Trim the start of a ring that has not reached its limit, so its
        // start index is not zero when it next needs to grow.
        let list = CircularBufferLineList(maxLength: 1_000)
        let buffer = Buffer(cols: 4, rows: 2, tabStopWidth: 8, scrollback: 998)
        list.owner = buffer
        func line(_ n: Int) -> BufferLine {
            let line = BufferLine(cols: 4)
            line[0] = CharData(attribute: CharData.defaultAttr, scalar: UnicodeScalar(UInt8(65 + n % 26)))
            return line
        }
        for n in 0..<60 { list.push(line(n)) }
        list.trimStart(count: 30)
        for n in 60..<200 { list.push(line(n)) }
        #expect(list.count == 170)
        for i in 0..<list.count {
            let expected = Character(UnicodeScalar(UInt8(65 + (i + 30) % 26)))
            #expect(list[i][0].getCharacter() == expected, "index \(i)")
        }
    }
}
