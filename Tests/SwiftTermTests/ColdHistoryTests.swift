//
//  ColdHistoryTests.swift
//
//  Cold history moves scrollback rows out of the line ring into a compact
//  encoding (HistoryRowCodec) and restores them when read. Nothing about that
//  may be observable, so most tests here drive the same output into a terminal
//  that compacts and one that doesn't, and compare every cell of every row.
//

import Foundation
import Testing

@testable import SwiftTerm

/// A small deterministic generator, so failures reproduce.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

@Suite final class ColdHistoryCodecTests {
    private func roundTrip(_ cells: [UInt64], sourceLocation: SourceLocation = #_sourceLocation) {
        cells.withUnsafeBufferPointer { source in
            let layout = HistoryRowCodec.layout(of: source)
            #expect(layout.count == cells.count, sourceLocation: sourceLocation)
            #expect(layout.contentWidth == 0 || layout.wordCount < cells.count,
                    "an encoding is only chosen when it is smaller", sourceLocation: sourceLocation)
            var words = [UInt64](repeating: 0xdead_beef, count: layout.wordCount + 1)
            words.withUnsafeMutableBufferPointer {
                HistoryRowCodec.encode(source, layout: layout, into: $0.baseAddress!)
            }
            #expect(words.last == 0xdead_beef, "encode stays within wordCount",
                    sourceLocation: sourceLocation)
            var decoded = [UInt64](repeating: 0, count: cells.count + 1)
            words.withUnsafeBufferPointer { words in
                decoded.withUnsafeMutableBufferPointer {
                    HistoryRowCodec.decode(layout, from: words.baseAddress!, into: $0.baseAddress!)
                }
            }
            #expect(Array(decoded.prefix(cells.count)) == cells, sourceLocation: sourceLocation)
            #expect(decoded.last == 0, "decode stays within count", sourceLocation: sourceLocation)
        }
    }

    private func cell(content: UInt64, template: UInt64) -> UInt64 {
        (template & ~PackedCell.contentMask) | ((content << PackedCell.contentShift) & PackedCell.contentMask)
    }

    @Test func emptyRow() {
        let layout = [UInt64]().withUnsafeBufferPointer { HistoryRowCodec.layout(of: $0) }
        #expect(layout == HistoryRowLayout(count: 0, runCount: 0, contentWidth: 0))
        #expect(layout.wordCount == 0)
    }

    @Test func plainTextUsesOneByteACell() {
        let template = PackedCell.makeUnchecked(contentTag: .codepoint, content: 0, styleID: 3,
                                                widthState: .narrow, isProtected: false,
                                                payloadCode: 0, semanticContentCode: 6).rawValue
        let text = Array("The quick brown fox jumps over the lazy dog, again and again and again.".utf8)
        let cells = text.map { cell(content: UInt64($0), template: template) }
        cells.withUnsafeBufferPointer {
            let layout = HistoryRowCodec.layout(of: $0)
            #expect(layout.runCount == 1 && layout.contentWidth == 1)
            // One template, one start, one byte per character.
            #expect(layout.wordCount == 1 + 1 + (text.count + 7) / 8)
        }
        roundTrip(cells)
    }

    /// Every length around the eight-cell vector blocks, with runs that change
    /// inside, at, and across block boundaries, and each content width.
    @Test func blockBoundaries() {
        let templates: [UInt64] = [0, 1 << PackedCell.styleIDShift, 2 << PackedCell.styleIDShift,
                                   UInt64(PackedCell.WidthState.wide.rawValue) << PackedCell.widthStateShift]
        for length in 0...40 {
            for runLength in [1, 3, 7, 8, 9, 16, 41] {
                for maxContent: UInt64 in [0x7f, 0xff, 0x100, 0xffff, 0x1_0000, 0xff_ffff] {
                    let cells = (0..<length).map { index in
                        cell(content: UInt64(index * 37) % (maxContent + 1) | (index == length / 2 ? maxContent : 0),
                             template: templates[(index / runLength) % templates.count])
                    }
                    roundTrip(cells)
                }
            }
        }
    }

    @Test func randomRows() {
        var random = SplitMix64(state: 42)
        for _ in 0..<3_000 {
            let length = Int.random(in: 0...300, using: &random)
            let runChance = [0.0, 0.01, 0.1, 0.5, 1.0].randomElement(using: &random)!
            let maxContent: UInt64 = [0xff, 0xffff, 0xff_ffff].randomElement(using: &random)!
            var template = random.next() & ~PackedCell.contentMask
            var cells: [UInt64] = []
            for _ in 0..<length {
                if Double.random(in: 0..<1, using: &random) < runChance {
                    template = random.next() & ~PackedCell.contentMask
                }
                cells.append(cell(content: UInt64.random(in: 0...maxContent, using: &random),
                                  template: template))
            }
            roundTrip(cells)
        }
    }

    @Test func alternatingWideCellsAreStoredRaw() {
        let head = UInt64(PackedCell.WidthState.wide.rawValue) << PackedCell.widthStateShift
        let tail = UInt64(PackedCell.WidthState.spacerTail.rawValue) << PackedCell.widthStateShift
        let cells = (0..<40).map { index in
            index % 2 == 0 ? cell(content: 0x65e5 + UInt64(index), template: head) : tail
        }
        let layout = cells.withUnsafeBufferPointer { HistoryRowCodec.layout(of: $0) }
        #expect(layout.contentWidth == 0 && layout.wordCount == 40)
        roundTrip(cells)
    }
}

@Suite final class ColdHistoryTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    private typealias Pair = (cold: Terminal, plain: Terminal)

    private func makePair(cols: Int = 30, rows: Int = 6, scrollback: Int = 200) -> Pair {
        let options = TerminalOptions(cols: cols, rows: rows, scrollback: scrollback)
        return (Terminal(delegate: self, options: options), Terminal(delegate: self, options: options))
    }

    private func feed(_ pair: Pair, _ text: String) {
        pair.cold.feed(text: text)
        pair.plain.feed(text: text)
    }

    /// Everything a row shows, read without restoring cold rows.
    private func describe(_ line: BufferLine) -> [String] {
        var cells = (0..<line.count).map { col -> String in
            let cell = line[col]
            return "\(cell.getText())|\(cell.attribute)|\(cell.width)|\(String(describing: cell.getPayload()))|\(cell.semanticContent)"
        }
        cells.append("wrapped=\(line.isWrapped) bidi=\(line.bidiState) mode=\(line.renderMode)")
        return cells
    }

    private func rows(_ terminal: Terminal) -> [[String]] {
        let buffer = terminal.buffer
        return (0..<buffer.lines.count).map { describe(buffer.readOnlyLine($0)) }
    }

    private func expectSame(_ pair: Pair, sourceLocation: SourceLocation = #_sourceLocation) {
        let a = pair.cold.buffer, b = pair.plain.buffer
        #expect(a.lines.count == b.lines.count, sourceLocation: sourceLocation)
        #expect(a.yBase == b.yBase && a.yDisp == b.yDisp && a.x == b.x && a.y == b.y,
                sourceLocation: sourceLocation)
        #expect(a.totalLinesTrimmed == b.totalLinesTrimmed, sourceLocation: sourceLocation)
        let coldRows = rows(pair.cold), plainRows = rows(pair.plain)
        for row in 0..<min(coldRows.count, plainRows.count) where coldRows[row] != plainRows[row] {
            let diff = zip(coldRows[row], plainRows[row]).enumerated().first { $0.element.0 != $0.element.1 }
            Issue.record("row \(row) differs at \(diff.map { "\($0.offset): \($0.element.0) vs \($0.element.1)" } ?? "length")",
                         sourceLocation: sourceLocation)
            break
        }
        for row in 0..<min(a.lines.count, b.lines.count) {
            #expect(a.isRowWrapped(row) == b.isRowWrapped(row), "row \(row)", sourceLocation: sourceLocation)
        }
    }

    private func compact(_ terminal: Terminal) {
        var steps = 0
        while terminal.compactHistory(.incremental) == .pending {
            steps += 1
            precondition(steps < 10_000, "compaction does not finish")
        }
    }

    /// A mix of output: styles, colors, wide and combined characters, links,
    /// soft wraps, blank lines and erased backgrounds.
    private func output(_ count: Int, seed: UInt64) -> String {
        var random = SplitMix64(state: seed)
        let pieces = [
            "plain text", "\u{1b}[1;31mbold red\u{1b}[0m", "\u{1b}[38;2;10;200;30mtrue color\u{1b}[0m",
            "\u{1b}[4:3m\u{1b}[58:5:200mcurly\u{1b}[0m", "日本語", "e\u{301}a\u{308}", "👩‍👩‍👧", "🇺🇸",
            "\u{1b}]8;;https://example.com\u{1b}\\link\u{1b}]8;;\u{1b}\\", "𝔘𝔫𝔦", "\t", "  ",
            "\u{1b}[44m blue \u{1b}[0m", "\u{1b}[7minverse\u{1b}[27m", "\u{1b}[43m\u{1b}[K\u{1b}[0m",
        ]
        var text = ""
        for i in 0..<count {
            text += "\(i) "
            for _ in 0..<Int.random(in: 0...8, using: &random) {
                text += pieces.randomElement(using: &random)! + " "
            }
            if Int.random(in: 0..<5, using: &random) == 0 {
                text += String(repeating: "wrap", count: Int.random(in: 5...25, using: &random))
            }
            text += "\r\n"
        }
        return text
    }

    // MARK: Moving rows out and back

    @Test func compactionMovesHistoryOutAndChangesNothingVisible() {
        let pair = makePair()
        feed(pair, output(150, seed: 1))
        compact(pair.cold)
        let storage = pair.cold.historyStorage
        #expect(storage.coldRows > 100)
        #expect(storage.residentRows + storage.coldRows == pair.cold.buffer.lines.count)
        #expect(pair.cold.buffer.yBase > 0)
        // The screen stays in the ring.
        for row in pair.cold.buffer.yBase..<pair.cold.buffer.lines.count {
            #expect(pair.cold.buffer.residentLine(row) != nil)
        }
        expectSame(pair)
    }

    @Test func outputAfterCompactionMatches() {
        // A small ring, so cold rows are recycled off the top many times.
        let pair = makePair(cols: 25, rows: 5, scrollback: 40)
        for round in 0..<12 {
            feed(pair, output(17, seed: UInt64(round)))
            if round % 3 != 2 { compact(pair.cold) }
            expectSame(pair)
        }
        // Rows dropped while cold are released with them.
        #expect(pair.cold.historyStorage.coldRows <= 40)
    }

    @Test func incrementalStepsAreBoundedAndFinish() {
        let terminal = makePair(scrollback: 5_000).cold
        terminal.feed(text: output(3_000, seed: 9))
        var steps = 0
        var previous = 0
        while terminal.compactHistory(.incremental) == .pending {
            let cold = terminal.historyStorage.coldRows
            #expect(cold - previous <= 256)
            previous = cold
            steps += 1
        }
        #expect(steps >= 3_000 / 256)
        #expect(terminal.historyStorage.coldRows >= 2_900)
        // Nothing changed: a new pass and its verification pass find nothing,
        // one scan-bounded step at a time, and move nothing.
        let cold = terminal.historyStorage.coldRows
        let rows = terminal.buffer.yBase
        var extraSteps = 1
        while terminal.compactHistory(.incremental) == .pending { extraSteps += 1 }
        #expect(extraSteps <= 2 * ((rows + 4_095) / 4_096))
        #expect(terminal.historyStorage.coldRows == cold)
    }

    @Test func readingARowRestoresItAndCompactionMovesItBack() {
        let pair = makePair()
        feed(pair, output(100, seed: 3))
        compact(pair.cold)
        let cold = pair.cold.historyStorage.coldRows
        let activity = pair.cold.historyActivity
        let row = pair.cold.buffer.totalLinesTrimmed + 10
        let restored = pair.cold.getScrollInvariantLine(row: row)!
        let expected = pair.plain.getScrollInvariantLine(row: row)!
        #expect(describe(restored) == describe(expected))
        #expect(pair.cold.historyStorage.coldRows == cold - 1)
        #expect(pair.cold.historyActivity != activity)
        // It is back in the ring for good: writing to it sticks.
        #expect(pair.cold.buffer.residentLine(10) === restored)
        compact(pair.cold)
        // `restored` still refers to the row, so it stays in the ring.
        #expect(pair.cold.historyStorage.coldRows == cold - 1)
        _ = consume restored
        compact(pair.cold)
        #expect(pair.cold.historyStorage.coldRows == cold)
        expectSame(pair)
    }

    @Test func readOnlyAccessDoesNotRestore() {
        let pair = makePair()
        feed(pair, output(100, seed: 4))
        compact(pair.cold)
        let cold = pair.cold.historyStorage.coldRows
        let buffer = pair.cold.buffer
        for row in buffer.totalLinesTrimmed..<(buffer.totalLinesTrimmed + buffer.lines.count) {
            let line = buffer.readScrollInvariantLine(row: row)!
            let expected = pair.plain.getScrollInvariantLine(row: row)!
            #expect(describe(line) == describe(expected))
        }
        #expect(pair.cold.historyStorage.coldRows == cold)
    }

    @Test func rowsInTheViewportStay() {
        let pair = makePair(rows: 6)
        feed(pair, output(80, seed: 5))
        // Scroll the view back into history.
        pair.cold.buffer.yDisp = 20
        pair.plain.buffer.yDisp = 20
        pair.cold.userScrolling = true
        compact(pair.cold)
        for row in 20..<26 {
            #expect(pair.cold.buffer.residentLine(row) != nil, "viewport row \(row)")
        }
        #expect(pair.cold.buffer.residentLine(19) == nil)
        expectSame(pair)
    }

    @Test func rowsReferencedElsewhereStay() {
        let pair = makePair()
        feed(pair, output(60, seed: 6))
        let held = pair.cold.buffer.lines[5]
        compact(pair.cold)
        #expect(pair.cold.buffer.residentLine(5) === held)
        #expect(pair.cold.buffer.residentLine(6) == nil)
        // A change through the reference is still visible in the buffer.
        held[0] = CharData(attribute: CharData.defaultAttr, scalar: "Z")
        #expect(pair.cold.buffer.readOnlyLine(5)[0].getCharacter() == "Z")
    }

    @Test func semanticPromptRowsStayAndPromptsStillResolve() {
        let pair = makePair(cols: 40, rows: 6, scrollback: 300)
        for i in 0..<40 {
            feed(pair, "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}command \(i)\r\n\u{1b}]133;C\u{7}")
            feed(pair, output(3, seed: UInt64(100 + i)))
            feed(pair, "\u{1b}]133;D;0\u{7}")
        }
        feed(pair, "\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}")
        compact(pair.cold)
        #expect(pair.cold.historyStorage.coldRows > 0)
        let buffer = pair.cold.buffer
        for row in 0..<buffer.lines.count {
            let kind = buffer.semanticRowKind(at: row)
            #expect(kind == pair.plain.buffer.semanticRowKind(at: row), "row \(row)")
            if let line = buffer.residentLine(row), line.semanticMarks.isEmpty == false {
                continue
            }
        }
        // Rows carrying marks were never moved.
        for row in 0..<pair.plain.buffer.lines.count
        where !pair.plain.buffer.lines[row].semanticMarks.isEmpty {
            #expect(buffer.residentLine(row) != nil, "marked row \(row)")
        }
        #expect(buffer.semanticPromptInvariantsHold())
        #expect(buffer.semanticPromptStartRow == pair.plain.buffer.semanticPromptStartRow)
        expectSame(pair)
    }

    @Test func resizingRestoresForReflowAndMatches() {
        let pair = makePair(cols: 30, rows: 6, scrollback: 300)
        feed(pair, output(120, seed: 7))
        compact(pair.cold)
        // Rows only: history stays cold.
        pair.cold.resize(cols: 30, rows: 9)
        pair.plain.resize(cols: 30, rows: 9)
        #expect(pair.cold.historyStorage.coldRows > 0)
        expectSame(pair)
        for (cols, rows) in [(18, 6), (45, 12), (12, 4), (30, 6)] {
            compact(pair.cold)
            pair.cold.resize(cols: cols, rows: rows)
            pair.plain.resize(cols: cols, rows: rows)
            #expect(pair.cold.historyStorage.coldRows == 0)
            expectSame(pair)
        }
    }

    @Test func clearingScrollbackAndResetDropCold() {
        let pair = makePair()
        feed(pair, output(100, seed: 8))
        compact(pair.cold)
        feed(pair, "\u{1b}[3J")
        #expect(pair.cold.historyStorage.coldRows == 0 || pair.cold.buffer.yBase == 0)
        compact(pair.cold)
        expectSame(pair)
        feed(pair, output(100, seed: 9))
        compact(pair.cold)
        feed(pair, "\u{1b}c")
        #expect(pair.cold.historyStorage.coldRows == 0)
        feed(pair, output(50, seed: 10))
        expectSame(pair)
    }

    @Test func shrinkingTheHistoryLimitDropsColdRows() {
        let pair = makePair(scrollback: 300)
        feed(pair, output(250, seed: 11))
        compact(pair.cold)
        pair.cold.changeHistorySize(50)
        pair.plain.changeHistorySize(50)
        compact(pair.cold)
        #expect(pair.cold.historyStorage.coldRows <= 50)
        expectSame(pair)
    }

    @Test func alternateScreenLeavesHistoryIntact() {
        let pair = makePair()
        feed(pair, output(90, seed: 12))
        feed(pair, "\u{1b}[?1049h")
        compact(pair.cold)
        #expect(pair.cold.historyStorage.coldRows > 0)
        feed(pair, output(20, seed: 13))
        feed(pair, "\u{1b}[?1049l")
        expectSame(pair)
    }

    @Test func searchAndSelectionReadColdRowsWithoutRestoring() {
        let pair = makePair(cols: 40, rows: 5, scrollback: 400)
        feed(pair, output(200, seed: 14))
        feed(pair, "needle in the history\r\n")
        feed(pair, output(100, seed: 15))
        compact(pair.cold)
        let cold = pair.cold.historyStorage.coldRows
        let coldSearch = SearchService(terminal: pair.cold)
        let plainSearch = SearchService(terminal: pair.plain)
        let options = SearchOptions()
        let found = coldSearch.findNext(term: "needle", options: options)
        #expect(found != nil)
        #expect(found == plainSearch.findNext(term: "needle", options: options))
        #expect(pair.cold.historyStorage.coldRows == cold)

        let coldSelection = SelectionService(terminal: pair.cold)
        let plainSelection = SelectionService(terminal: pair.plain)
        coldSelection.selectAll()
        plainSelection.selectAll()
        #expect(coldSelection.getSelectedText() == plainSelection.getSelectedText())
        #expect(pair.cold.historyStorage.coldRows == cold)
    }

    @Test func coldRowsAreSmall() {
        let terminal = makePair(cols: 80, rows: 24, scrollback: 10_000).cold
        var text = ""
        for i in 0..<10_000 {
            text += String(format: "%05d ", i) + String(repeating: "lorem ipsum ", count: 6).prefix(66) + "\r\n"
        }
        terminal.feed(text: text)
        terminal.compactHistory(.full)
        let storage = terminal.historyStorage
        #expect(storage.coldRows >= 9_970)
        // 32 bytes of row state plus one template, one start and 72 bytes.
        #expect(storage.coldBytes / storage.coldRows <= 32 + 8 + 8 + 72 + 8)
    }
}
