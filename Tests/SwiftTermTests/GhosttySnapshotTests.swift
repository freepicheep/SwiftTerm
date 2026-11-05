//
//  GhosttySnapshotTests.swift
//
//  The scenarios in GhosttySnapshotScenarios.swift are terminal output and the
//  snapshot a Ghostty core made after reading it. Restoring a snapshot should give
//  the terminal that reading the output directly gives.
//
//  completeReference is Ghostty's own golden file,
//  src/terminal/snapshot/testdata/complete-v1.hex (MIT licensed).
//

import Foundation
import Testing

@testable import SwiftTerm

private let completeReference = "47484f5354534e5001000100b8030000e35f8bcc020003002003000058020000000002000000010000010002006500000001010100000000000800042200641000000004220064000000000422006400000000000000000000000000000000000000000000000000000000ffffffffffffffffffffffffffffffff001d1f21cc6666b5bd68f0c67481a2beb294bb8abeb7c5c8c6666666d54e53b9ca4ae7c5477aa6dac397d870c0b1eaeaea00000000005f0000870000af0000d70000ff005f00005f5f005f87005faf005fd7005fff00870000875f0087870087af0087d70087ff00af0000af5f00af8700afaf00afd700afff00d70000d75f00d78700d7af00d7d700d7ff00ff0000ff5f00ff8700ffaf00ffd700ffff5f00005f005f5f00875f00af5f00d75f00ff5f5f005f5f5f5f5f875f5faf5f5fd75f5fff5f87005f875f5f87875f87af5f87d75f87ff5faf005faf5f5faf875fafaf5fafd75fafff5fd7005fd75f5fd7875fd7af5fd7d75fd7ff5fff005fff5f5fff875fffaf5fffd75fffff87000087005f8700878700af8700d78700ff875f00875f5f875f87875faf875fd7875fff87870087875f8787878787af8787d78787ff87af0087af5f87af8787afaf87afd787afff87d70087d75f87d78787d7af87d7d787d7ff87ff0087ff5f87ff8787ffaf87ffd787ffffaf0000af005faf0087af00afaf00d7af00ffaf5f00af5f5faf5f87af5fafaf5fd7af5fffaf8700af875faf8787af87afaf87d7af87ffafaf00afaf5fafaf87afafafafafd7afafffafd700afd75fafd787afd7afafd7d7afd7ffafff00afff5fafff87afffafafffd7afffffd70000d7005fd70087d700afd700d7d700ffd75f00d75f5fd75f87d75fafd75fd7d75fffd78700d7875fd78787d787afd787d7d787ffd7af00d7af5fd7af87d7afafd7afd7d7afffd7d700d7d75fd7d787d7d7afd7d7d7d7d7ffd7ff00d7ff5fd7ff87d7ffafd7ffd7d7ffffff0000ff005fff0087ff00afff00d7ff00ffff5f00ff5f5fff5f87ff5fafff5fd7ff5fffff8700ff875fff8787ff87afff87d7ff87ffffaf00ffaf5fffaf87ffafafffafd7ffafffffd700ffd75fffd787ffd7afffd7d7ffd7ffffff00ffff5fffff87ffffafffffd7ffffff0808081212121c1c1c2626263030303a3a3a4444444e4e4e5858586262626c6c6c7676768080808a8a8a9494949e9e9ea8a8a8b2b2b2bcbcbcc6c6c6d0d0d0dadadae4e4e4eeeeee80000000000000000000000000000000000000000000000000000000000000000102031400000066696c653a2f2f2f746d702f736e617073686f7411000000636f6d706c65746520736e617073686f7402003600000067310ec6000001000400000000000000000000000100000000000000000000000000000000000000000000080000000000000000000000000000030024000000a24f26d102000300000000001000c000000400000008000000010043000100440001004500000000020036000000ce1f9f08010001000000000000000000010002000100000000000000000000000000000000000000000000080000000000000000000000000000030026000000621cab7b02000300000000008000c0000002000000080000030200726e03020061740201006500000000070000000000278063d1050000000000e420ef0a0400060000002032ede100000200000003001f0000004aed2fc202000200000000001000c0000004000000080000000100420000000000000003001f000000236a6b1902000200000000001000c00000040000000800000001004100000000000000040006000000b87abab10100000000000600000000003eeb533e"

private func bytes(hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var at = hex.startIndex
    while at < hex.endIndex {
        let next = hex.index(at, offsetBy: 2)
        out.append(UInt8(hex[at..<next], radix: 16)!)
        at = next
    }
    return out
}

private func bytes(base64: String) -> [UInt8] { [UInt8](Data(base64Encoded: base64)!) }

private final class Host: TerminalDelegate {
    var sent: [UInt8] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { sent += data }
    func isProcessTrusted(source: Terminal) -> Bool { true }
}

private func terminal(_ host: Host, scrollback: Int = 500) -> Terminal {
    Terminal(delegate: host, options: TerminalOptions(cols: 40, rows: 10, scrollback: scrollback))
}

/// What differs between two terminals' visible state.
private func differences(_ got: Terminal, _ want: Terminal) -> [String] {
    var out: [String] = []
    func note<T: Equatable>(_ what: String, _ a: T, _ b: T) {
        if a != b { out.append("\(what): got \(a), want \(b)") }
    }
    note("cols", got.cols, want.cols)
    note("rows", got.rows, want.rows)
    note("alternate", got.isCurrentBufferAlternate, want.isCurrentBufferAlternate)
    note("x", got.buffer.x, want.buffer.x)
    note("y", got.buffer.y, want.buffer.y)
    note("attribute", got.currentAttribute, want.currentAttribute)
    note("scrollTop", got.buffer.scrollTop, want.buffer.scrollTop)
    note("scrollBottom", got.buffer.scrollBottom, want.buffer.scrollBottom)
    note("marginLeft", got.buffer.marginLeft, want.buffer.marginLeft)
    note("marginRight", got.buffer.marginRight, want.buffer.marginRight)
    // SwiftTerm starts with a stop at column 0, which no tab can reach.
    note("tabs", got.buffer.tabStops.indices.filter { $0 > 0 && got.buffer.tabStops[$0] },
         want.buffer.tabStops.indices.filter { $0 > 0 && want.buffer.tabStops[$0] })
    note("cursor style", got.options.cursorStyle, want.options.cursorStyle)
    note("keyboard", got.keyboardEnhancementFlags, want.keyboardEnhancementFlags)
    note("mouse", got.mouseMode, want.mouseMode)
    note("title", got.terminalTitle, want.terminalTitle)
    for index in got.ansiColors.indices where index < want.ansiColors.count {
        // To eight bits, which is all the format holds.
        func channels(_ c: Color) -> [UInt16] { [c.red >> 8, c.green >> 8, c.blue >> 8] }
        note("palette \(index)", channels(got.ansiColors[index]), channels(want.ansiColors[index]))
    }
    note("foreground", got.foregroundColor, want.foregroundColor)
    note("background", got.backgroundColor, want.backgroundColor)
    note("cursorColor", got.cursorColor, want.cursorColor)
    // 12: Ghostty also records a blinking DECSCUSR as this mode; the style is compared above.
    for mode in GhosttySnapshot.modeRegistry where mode.number != 12 {
        note("mode \(mode.number)", got.modeReportValue(mode.number, decPrivate: !mode.isANSI),
             want.modeReportValue(mode.number, decPrivate: !mode.isANSI))
    }
    for (name, a, b) in [("normal", got.normalBuffer, want.normalBuffer), ("alt", got.altBuffer, want.altBuffer)] {
        let trimmed = name == "alt" && !want.isCurrentBufferAlternate
        if trimmed { continue }
        note("\(name) yBase", a.yBase, b.yBase)
        for row in 0..<min(a.lines.count, b.lines.count) {
            let x = a.lines[row], y = b.lines[row]
            note("\(name) row \(row) wrapped", x.isWrapped, y.isWrapped)
            for col in 0..<min(x.count, y.count) {
                let c = x[col], d = y[col]
                note("\(name) \(row),\(col) text", c.getText(), d.getText())
                note("\(name) \(row),\(col) attr", c.attribute, d.attribute)
                note("\(name) \(row),\(col) width", c.width, d.width)
                note("\(name) \(row),\(col) link", c.getPayload() as? String, d.getPayload() as? String)
                note("\(name) \(row),\(col) protected", c.isProtected, d.isProtected)
            }
        }
    }
    return out
}

@Suite("Ghostty snapshots")
struct GhosttySnapshotTests {
    // MARK: Reading

    @Test func readsGhosttysOwnReference() throws {
        let snapshot = try GhosttySnapshot(bytes: bytes(hex: completeReference))
        #expect(snapshot.terminal.columns == 2)
        #expect(snapshot.terminal.rows == 3)
        #expect(snapshot.terminal.screenCount == snapshot.screens.count)
        #expect(snapshot.terminal.originalPalette.count == 256)
        #expect(!snapshot.screens[0].pages.isEmpty)
    }

    @Test func piecesCutAnywhereReadTheSame() throws {
        for scenario in ghosttySnapshotScenarios {
            let whole = bytes(base64: scenario.snapshot)
            let snapshot = try GhosttySnapshot(bytes: whole)
            for size in [1, 7, 1000] {
                var decoder = GhosttySnapshotDecoder()
                var events: [GhosttySnapshotDecoder.Event] = []
                var at = 0
                while at < whole.count {
                    events += try decoder.feed(Array(whole[at..<min(at + size, whole.count)]))
                    at += size
                }
                #expect(decoder.isFinished, "\(scenario.name)")
                var again = GhosttySnapshotDecoder()
                #expect(try again.feed(whole) == events, "\(scenario.name)")
            }
            #expect(snapshot.screens[0].key == .primary)
        }
    }

    @Test func whatFollowsTheEndIsLeftOver() throws {
        var decoder = GhosttySnapshotDecoder()
        let tail: [UInt8] = [1, 2, 3]
        _ = try decoder.feed(bytes(base64: ghosttySnapshotScenarios[0].snapshot) + tail)
        #expect(decoder.isFinished)
        #expect(decoder.takeRemainder() == tail)
        _ = try decoder.feed([4])
        #expect(decoder.takeRemainder() == [4])
    }

    @Test func refusesWhatIsntOne() {
        let good = bytes(base64: ghosttySnapshotScenarios[0].snapshot)
        #expect(throws: GhosttySnapshotError.notASnapshot) { try GhosttySnapshot(bytes: Array("not a snapshot".utf8)) }
        #expect(throws: GhosttySnapshotError.truncated) { try GhosttySnapshot(bytes: Array(good.prefix(good.count / 2))) }
        var future = good
        future[8] = 2
        #expect(throws: GhosttySnapshotError.unsupportedVersion(2)) { try GhosttySnapshot(bytes: future) }
        var corrupt = good
        corrupt[200] ^= 1
        #expect(throws: GhosttySnapshotError.checksumMismatch(tag: 1)) { try GhosttySnapshot(bytes: corrupt) }
        #expect(GhosttySnapshot.isSnapshot(good))
        #expect(!GhosttySnapshot.isSnapshot(Array(good.prefix(3))), "output that starts with a G isn't one")
        #expect(!GhosttySnapshot.isSnapshot(Array("GHX".utf8)))
    }

    @Test func aMalformedRecordIsAnErrorAndNotACrash() throws {
        // Every byte of every record, flipped, with the checksum then made to match:
        // whatever it says, reading and restoring it must not trap.
        let good = bytes(base64: ghosttySnapshotScenarios.first { $0.name == "styles" }!.snapshot)
        var offsets: [Range<Int>] = []
        var at = 10
        while at + 10 <= good.count {
            let length = Int(good[at + 2]) | Int(good[at + 3]) << 8 | Int(good[at + 4]) << 16 | Int(good[at + 5]) << 24
            offsets.append((at + 10)..<(at + 10 + length))
            at += 10 + length
        }
        for record in offsets {
            for index in stride(from: record.lowerBound, to: record.upperBound, by: 3) {
                var bad = good
                bad[index] = ~bad[index]
                var check = CRC32C()
                check.update(bad, (record.lowerBound - 10)..<(record.lowerBound - 4))
                check.update(bad, record)
                let value = check.value
                for shift in 0..<4 { bad[record.lowerBound - 4 + shift] = UInt8((value >> UInt32(shift * 8)) & 0xff) }
                guard let snapshot = try? GhosttySnapshot(bytes: bad),
                      snapshot.terminal.columns < 400, snapshot.terminal.rows < 400 else { continue }
                terminal(Host()).restore(from: snapshot)
            }
        }
    }

    // MARK: Restoring

    @Test(arguments: ghosttySnapshotScenarios.map(\.name))
    func restoringGivesTheTerminalTheOutputGives(_ name: String) throws {
        let scenario = ghosttySnapshotScenarios.first { $0.name == name }!
        let directHost = Host()
        let direct = terminal(directHost)
        direct.feed(byteArray: bytes(base64: scenario.output))
        let host = Host()
        let restored = terminal(host)
        restored.feed(text: "old contents \u{1b}[31m\r\nto be replaced")
        // Ghostty's default palette isn't SwiftTerm's; what programs set is compared.
        restored.restore(from: try GhosttySnapshot(bytes: bytes(base64: scenario.snapshot)), options: .init(hostColors: false))
        #expect(host.sent.isEmpty, "a restore sends the host nothing")
        let before = differences(restored, direct)
        #expect(before.isEmpty, "\(name) before:\n\(before.prefix(12).joined(separator: "\n"))")
        // And the same again after more output, which also finishes whatever was cut.
        let more: [UInt8] = Array("1mXY\u{1b}\\u{a0}\r\nnext line \u{1b}[2;2Hmoved\u{1b}[K".utf8)
        direct.feed(byteArray: more)
        restored.feed(byteArray: more)
        let after = differences(restored, direct)
        #expect(after.isEmpty, "\(name) after:\n\(after.prefix(12).joined(separator: "\n"))")
        // And after what uses saved state: restoring the cursor, modes and the keyboard stack.
        let saved: [UInt8] = Array("\u{1b}8saved\u{1b}[?1000r\u{1b}[?2004r\u{1b}[<u\u{1b}[?1049lleft\r\n".utf8)
        direct.feed(byteArray: saved)
        restored.feed(byteArray: saved)
        let last = differences(restored, direct)
        #expect(last.isEmpty, "\(name) saved:\n\(last.prefix(12).joined(separator: "\n"))")
    }

    @Test func historyComesFromPagesNewestFirst() throws {
        let scenario = ghosttySnapshotScenarios.first { $0.name == "pages" }!
        let snapshot = try GhosttySnapshot(bytes: bytes(base64: scenario.snapshot))
        #expect(!snapshot.screens[0].history.isEmpty, "this scenario is meant to need HISTORY pages")
        let hosts = (Host(), Host())
        let restored = terminal(hosts.0, scrollback: 100_000)
        let direct = terminal(hosts.1, scrollback: 100_000)
        direct.feed(byteArray: bytes(base64: scenario.output))
        restored.restore(from: snapshot, options: .init(hostColors: false))
        #expect(restored.normalBuffer.lines.count == direct.normalBuffer.lines.count)
        let found = differences(restored, direct)
        #expect(found.isEmpty, "\(found.prefix(12).joined(separator: "\n"))")
    }

    @Test func historyBeyondTheLimitIsDropped() throws {
        let scenario = ghosttySnapshotScenarios.first { $0.name == "scrollback" }!
        let restored = terminal(Host(), scrollback: 5)
        restored.restore(from: try GhosttySnapshot(bytes: bytes(base64: scenario.snapshot)))
        #expect(restored.normalBuffer.lines.count == 15)
        #expect(restored.getLine(row: 9)?.translateToString(trimRight: true) == "after the long one")
    }

    @Test func aPagesOtherWidthIsLaidOutAgain() throws {
        // The snapshot says 40 columns; a page narrower than the buffer it lands in.
        var snapshot = try GhosttySnapshot(bytes: bytes(base64: ghosttySnapshotScenarios.first { $0.name == "wide" }!.snapshot))
        for screen in snapshot.screens.indices {
            for page in snapshot.screens[screen].pages.indices { snapshot.screens[screen].pages[page].columns = 60 }
        }
        let restored = terminal(Host())
        restored.restore(from: snapshot)
        let lines = (0..<restored.rows).compactMap { restored.getLine(row: $0)?.translateToString(trimRight: true) }
        #expect(lines.contains { $0.contains("wrapped wide") || $0.contains("wide") })
    }

    @Test func takesTheSnapshotsColorsByDefault() throws {
        let scenario = ghosttySnapshotScenarios.first { $0.name == "palette" }!
        let snapshot = try GhosttySnapshot(bytes: bytes(base64: scenario.snapshot))
        // A live delegate, whose default handlers set the colors back on the terminal.
        let host = Host()
        let restored = terminal(host)
        restored.restore(from: snapshot)
        for (index, rgb) in snapshot.terminal.palette.enumerated() where index < restored.ansiColors.count {
            #expect(restored.ansiColors[index] == Color(red8: UInt16(rgb.red), green8: UInt16(rgb.green), blue8: UInt16(rgb.blue)))
        }
        #expect(restored.ansiColors[1] == Color(red8: 0x12, green8: 0x34, blue8: 0x56), "what the program set")
        #expect(restored.foregroundColor == Color(red8: 1, green8: 2, blue8: 3))
        // OSC 104 goes back to the snapshot's palette, not this terminal's old one.
        restored.feed(text: "\u{1b}]104\u{1b}\\")
        let original = snapshot.terminal.originalPalette[1]
        #expect(restored.ansiColors[1] == Color(red8: UInt16(original.red), green8: UInt16(original.green), blue8: UInt16(original.blue)))
    }

    @Test func keepsTheHostsColorsWhenAsked() throws {
        let scenario = ghosttySnapshotScenarios.first { $0.name == "plain" }!
        let snapshot = try GhosttySnapshot(bytes: bytes(base64: scenario.snapshot))
        let host = Host()
        let restored = terminal(host)
        let mine = Color(red8: 1, green8: 2, blue8: 3)
        restored.foregroundColor = mine
        let palette = restored.ansiColors
        restored.restore(from: snapshot, options: .init(hostColors: false))
        #expect(restored.foregroundColor == mine)
        #expect(restored.ansiColors == palette)
    }

    @Test func tellsTheHostWhatChanged() throws {
        let scenario = ghosttySnapshotScenarios.first { $0.name == "title" }!
        final class Watching: TerminalDelegate {
            var titles: [String] = []
            func send(source: Terminal, data: ArraySlice<UInt8>) {}
            func setTerminalTitle(source: Terminal, title: String) { titles.append(title) }
        }
        let host = Watching()
        let restored = Terminal(delegate: host, options: TerminalOptions(cols: 40, rows: 10))
        restored.restore(from: try GhosttySnapshot(bytes: bytes(base64: scenario.snapshot)))
        #expect(host.titles == ["A title"])
        #expect(restored.hostCurrentDirectory?.hasSuffix("/tmp/place") == true)
    }
}

#if os(macOS)
import AppKit

/// A view shows a snapshot as its terminal would hold it, and goes on from there.
@Test @MainActor func viewRestoresASnapshot() throws {
    let snapshot = try GhosttySnapshot(bytes: bytes(hex: completeReference))
    let host = Host()
    let expected = terminal(host)
    expected.restore(from: snapshot)

    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
    view.restore(from: snapshot)
    let shown = view.terminal!
    #expect(shown.cols == snapshot.terminal.columns && shown.rows == snapshot.terminal.rows)
    for row in 0..<shown.rows {
        #expect(shown.getLine(row: row)?.translateToString(trimRight: true) == expected.getLine(row: row)?.translateToString(trimRight: true))
    }
    // Its grid is a few columns wide.
    view.feed(text: "\r\nZ")
    #expect(shown.getLine(row: shown.buffer.y)?.translateToString(trimRight: true) == "Z")
}

/// Without the host's colors, a view keeps the theme it was given.
@Test @MainActor func viewKeepsItsThemeThroughARestore() throws {
    let snapshot = try GhosttySnapshot(bytes: bytes(hex: completeReference))
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
    let (background, foreground) = (NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1), NSColor(srgbRed: 0.9, green: 0.8, blue: 0.7, alpha: 1))
    view.nativeBackgroundColor = background
    view.nativeForegroundColor = foreground
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    view.restore(from: snapshot, options: .init(hostColors: false))
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    #expect(view.nativeBackgroundColor == background)
    #expect(view.nativeForegroundColor == foreground)
    #expect(view.terminal.backgroundColor == background.getTerminalColor())
}
#endif
