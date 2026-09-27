//
//  ModeReportValueTests.swift
//
//  Terminal.modeReportValue reads mode state the way DECRQM reports it, without
//  feeding a query through the parser.
//
import Foundation
import Testing

@testable import SwiftTerm

final class ModeReportValueTests: TerminalDelegate {
    var sent: [UInt8] = []

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        sent.append(contentsOf: data)
    }

    func makeTerminal() -> Terminal {
        Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))
    }

    @Test func tracksDecPrivateModes() {
        let terminal = makeTerminal()
        #expect(terminal.modeReportValue(2004) == 2)
        #expect(terminal.modeReportValue(1006) == 2)
        terminal.feed(text: "\u{1b}[?2004h\u{1b}[?1006h\u{1b}[?25l")
        #expect(terminal.modeReportValue(2004) == 1)
        #expect(terminal.modeReportValue(1006) == 1)
        #expect(terminal.modeReportValue(25) == 2)
        #expect(terminal.modeReportValue(9999) == 0)
    }

    @Test func tracksAnsiModes() {
        let terminal = makeTerminal()
        #expect(terminal.modeReportValue(4, decPrivate: false) == 2)
        terminal.feed(text: "\u{1b}[4h")
        #expect(terminal.modeReportValue(4, decPrivate: false) == 1)
    }

    @Test func matchesDecrqmReplies() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[?2004h\u{1b}[?1000h")
        for mode in [1, 6, 7, 25, 1000, 1002, 2004, 9999] {
            sent = []
            terminal.feed(text: "\u{1b}[?\(mode)$p")
            #expect(String(decoding: sent, as: UTF8.self) == "\u{1b}[?\(mode);\(terminal.modeReportValue(mode))$y")
        }
    }

    @Test func readsModesWithoutDisturbingAPartialSequence() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[?2004h")
        // Output that stopped partway through an OSC title.
        terminal.feed(text: "\u{1b}]2;half")
        sent = []
        #expect(terminal.modeReportValue(2004) == 1)
        #expect(sent.isEmpty)
        terminal.feed(text: " a title\u{1b}\\")
        #expect(terminal.terminalTitle == "half a title")
    }
}
