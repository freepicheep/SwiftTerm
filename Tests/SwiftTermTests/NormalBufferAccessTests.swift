//
//  NormalBufferAccessTests.swift
//
//  The normal buffer stays readable through the public API while the alternate
//  screen is active.
//
import Foundation
import Testing

import SwiftTerm

final class NormalBufferAccessTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    func makeTerminal() -> Terminal {
        Terminal(delegate: self, options: TerminalOptions(cols: 40, rows: 5, scrollback: 100))
    }

    private func text(_ buffer: Buffer) -> [String] {
        var out: [String] = []
        var row = buffer.totalLinesTrimmed
        while let line = buffer.getScrollInvariantLine(row: row) {
            out.append(line.translateToString(trimRight: true))
            row += 1
        }
        return out
    }

    @Test func normalBufferIsReadableUnderTheAlternateScreen() {
        let terminal = makeTerminal()
        for i in 1...8 { terminal.feed(text: "line \(i)\r\n") }
        terminal.feed(text: "prompt$ ")
        let before = text(terminal.normalBuffer)
        let cursor = (terminal.normalBuffer.x, terminal.normalBuffer.y)

        terminal.feed(text: "\u{1b}[?1049h\u{1b}[2J\u{1b}[Hfull screen app")
        #expect(terminal.isCurrentBufferAlternate)
        #expect(terminal.buffer === terminal.altBuffer)
        #expect(text(terminal.normalBuffer) == before)
        #expect(before.contains("line 1"))
        #expect(before.contains { $0.hasPrefix("prompt$") })
        #expect(terminal.normalBuffer.x == cursor.0)
        #expect(terminal.normalBuffer.y == cursor.1)

        // Switching away and back in one burst leaves the normal buffer current.
        terminal.feed(text: "\u{1b}[?1049lshell output\r\n\u{1b}[?1049h")
        #expect(text(terminal.normalBuffer).contains { $0.hasPrefix("prompt$ shell output") })
    }

    @Test func normalBufferKeepsItsGridWhileHidden() {
        let terminal = makeTerminal()
        terminal.feed(text: "hello")
        terminal.feed(text: "\u{1b}[?1049h")
        terminal.resize(cols: 60, rows: 8)
        #expect(terminal.altBuffer.cols == 60)
        #expect(terminal.normalBuffer.cols == 40)
        #expect(terminal.normalBuffer.rows == 5)
    }
}
