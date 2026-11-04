//
//  GhosttySnapshot.swift
//  SwiftTerm
//
//  A reader for Ghostty's binary terminal snapshot format, version 1
//  (`src/terminal/snapshot/snapshot.ksy` in Ghostty, MIT licensed). A snapshot
//  is a terminal's whole state as seen at one byte of its output: grid,
//  scrollback, alternate screen, modes, palette and cursor. Programs that run a
//  terminal on Ghostty's core, such as a multiplexer, send one to a client that
//  attaches, followed by the output after that byte, so the client misses nothing
//  and draws nothing twice.
//
//  Reading needs no terminal: `GhosttySnapshot(bytes:)` gives the whole snapshot,
//  and `GhosttySnapshotDecoder` reads one as it arrives, in pieces cut anywhere,
//  reporting each record, with what follows the snapshot left over.
//  `Terminal.restore(from:)` loads one into a terminal.
//
//  As the format asks, the framing is strict and the content is forgiving: a bad
//  checksum or an out-of-order record is an error, while an unknown style, an
//  invalid scalar or an out-of-range enum value degrades to the default.
//

#if !SWIFTTERM_EMBEDDED
import Foundation

/// Why a snapshot can't be read.
public enum GhosttySnapshotError: Error, Equatable, Sendable {
    /// The bytes don't start with the snapshot envelope.
    case notASnapshot
    /// A version of the format this reader doesn't know.
    case unsupportedVersion(UInt16)
    /// The bytes end before the snapshot does.
    case truncated
    /// A record's CRC32C doesn't match its contents.
    case checksumMismatch(tag: UInt16)
    /// A record that can't come at this point in a snapshot.
    case unexpectedRecord(tag: UInt16)
    /// A record declares more than `GhosttySnapshotDecoder.maximumRecordBytes`.
    case recordTooLarge(tag: UInt16, bytes: UInt32)
    /// A record's payload doesn't have the structure its fields declare.
    case malformed(tag: UInt16)
}

/// A terminal's state in Ghostty's snapshot format.
public struct GhosttySnapshot: Equatable, Sendable {
    /// The state shared by every screen.
    public var terminal: TerminalState
    /// The primary screen, and the alternate one when there is one.
    public var screens: [Screen]
    /// The output, cut at the snapshot, that hasn't finished: a partial escape
    /// sequence or UTF-8 scalar. It is fed once before the output that follows.
    public var continuation: [UInt8]

    /// The eight bytes every snapshot starts with.
    public static let magic: [UInt8] = [0x47, 0x48, 0x4f, 0x53, 0x54, 0x53, 0x4e, 0x50]
    /// The version of the format this reader understands.
    public static let version: UInt16 = 1

    /// Reads a whole snapshot. Bytes after its end are ignored; use
    /// `GhosttySnapshotDecoder` when they matter.
    public init(bytes: [UInt8]) throws {
        var decoder = GhosttySnapshotDecoder()
        var builder = Builder()
        for event in try decoder.feed(bytes) { try builder.take(event) }
        guard decoder.isFinished, let snapshot = builder.result() else { throw GhosttySnapshotError.truncated }
        self = snapshot
    }

    /// Whether `bytes` start with the snapshot envelope's magic.
    public static func isSnapshot(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: magic)
    }

    /// A screen's main or alternate role.
    public enum ScreenKey: UInt16, Equatable, Sendable {
        case primary = 0
        case alternate = 1
    }

    public enum CursorStyle: UInt8, Equatable, Sendable {
        case bar = 0
        case block = 1
        case underline = 2
        case blockHollow = 3
    }

    /// A color's default from the host and the value a program set, if any.
    public struct DynamicColor: Equatable, Sendable {
        public var hostDefault: RGB?
        public var override: RGB?
        /// What is in effect.
        public var effective: RGB? { override ?? hostDefault }
    }

    public struct RGB: Equatable, Hashable, Sendable {
        public var red, green, blue: UInt8
        public init(red: UInt8, green: UInt8, blue: UInt8) { (self.red, self.green, self.blue) = (red, green, blue) }
    }

    /// Terminal modes, by their bit in the format's stable registry.
    public struct Modes: Equatable, Sendable {
        public var rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }
        public func contains(_ mode: Mode) -> Bool { rawValue & (1 << UInt64(mode.bit)) != 0 }
    }

    /// One mode of the registry: its bit, its number and whether it's an ANSI mode
    /// rather than a DEC private one.
    public struct Mode: Equatable, Sendable {
        public let bit: Int
        public let number: Int
        public let isANSI: Bool
    }

    /// The format's mode registry, in bit order.
    public static let modeRegistry: [Mode] = {
        let ansi = [2, 4, 12, 20]
        let dec = [1, 3, 4, 5, 6, 7, 8, 9, 12, 25, 40, 45, 47, 66, 67, 69, 1000, 1002, 1003, 1004, 1005, 1006, 1007,
                   1015, 1016, 1035, 1036, 1039, 1045, 1047, 1048, 1049, 2004, 2026, 2027, 2031, 2033, 2048, 5522]
        var modes: [Mode] = []
        for number in ansi { modes.append(Mode(bit: modes.count, number: number, isANSI: true)) }
        for number in dec { modes.append(Mode(bit: modes.count, number: number, isANSI: false)) }
        return modes
    }()

    /// The TERMINAL record.
    public struct TerminalState: Equatable, Sendable {
        public var columns: Int
        public var rows: Int
        public var widthPixels: Int
        public var heightPixels: Int
        public var scrollTop: Int
        public var scrollBottom: Int
        public var scrollLeft: Int
        public var scrollRight: Int
        /// 0: main display; 1: status line.
        public var statusDisplay: UInt8
        public var activeScreen: ScreenKey
        public var screenCount: Int
        /// The last character printed, for REP; nil when there is none.
        public var previousCodepoint: UInt32?
        /// The cursor is the host's default rather than one a program chose.
        public var cursorIsDefault: Bool
        public var cursorDefaultStyle: CursorStyle
        public var cursorDefaultBlink: Bool?
        /// 0: full; 1: none; 2: last.
        public var shellRedraw: UInt8
        public var modifyOtherKeys2: Bool
        /// 0: none; 1: X10; 2: normal; 3: button; 4: any.
        public var mouseEvent: UInt8
        /// 0: X10; 1: UTF-8; 2: SGR; 3: urxvt; 4: SGR pixels.
        public var mouseFormat: UInt8
        public var mouseShiftCapture: Bool?
        /// The registry index of the pointer shape a program asked for.
        public var mouseShape: UInt8
        public var passwordInput: Bool
        public var modes: Modes
        public var savedModes: Modes
        public var defaultModes: Modes
        public var background: DynamicColor
        public var foreground: DynamicColor
        public var cursorColor: DynamicColor
        public var maxScrollbackBytes: UInt64
        public var maxScrollbackRows: UInt64
        /// Whether each column has a tab stop.
        public var tabStops: [Bool]
        /// The palette before anything a program set.
        public var originalPalette: [RGB]
        /// The colors programs set, by palette index.
        public var paletteOverrides: [Int: RGB]
        public var workingDirectory: String
        public var title: String

        /// The palette in effect.
        public var palette: [RGB] {
            var colors = originalPalette
            for (index, color) in paletteOverrides where index < colors.count { colors[index] = color }
            return colors
        }
    }

    /// A color as a style or cell refers to it.
    public enum Color: Equatable, Hashable, Sendable {
        case none
        case palette(UInt8)
        case rgb(RGB)
    }

    public struct Style: Equatable, Hashable, Sendable {
        public var foreground: Color = .none
        public var background: Color = .none
        public var underlineColor: Color = .none
        public var bold = false
        public var italic = false
        public var faint = false
        public var blink = false
        public var inverse = false
        public var invisible = false
        public var strikethrough = false
        public var overline = false
        /// 0: none; 1: single; 2: double; 3: curly; 4: dotted; 5: dashed.
        public var underline: UInt8 = 0
        public init() {}
    }

    /// A hyperlink: its identifier, as OSC 8 gave it, or the number of an implicit
    /// one, for one with none, and where it goes.
    public struct Hyperlink: Equatable, Hashable, Sendable {
        public enum ID: Equatable, Hashable, Sendable {
            case implicit(UInt32)
            case explicit(String)
        }
        public var id: ID
        public var uri: String
    }

    /// Four designated character sets, the slots in GL and GR, and a pending single
    /// shift. Character sets: 0 UTF-8, 1 ASCII, 2 British, 3 DEC special.
    public struct CharsetState: Equatable, Sendable {
        public var g: [UInt8]
        public var gl: UInt8
        public var gr: UInt8
        /// nil, or the slot the next character is taken from.
        public var singleShift: UInt8?
    }

    public struct SavedCursor: Equatable, Sendable {
        public var x, y: Int
        public var pen: Style
        public var isProtected: Bool
        public var pendingWrap: Bool
        public var origin: Bool
        public var charset: CharsetState
    }

    /// The role of content, per OSC 133.
    public enum SemanticContent: UInt8, Equatable, Sendable {
        case output = 0
        case input = 1
        case prompt = 2
    }

    /// The SCREEN record and the pages that follow it.
    public struct Screen: Equatable, Sendable {
        public var key: ScreenKey
        /// How many rows of history there are in all, as declared up front.
        public var historyRows: UInt64
        public var cursorX, cursorY: Int
        public var cursorStyle: CursorStyle
        public var pendingWrap: Bool
        public var cursorProtected: Bool
        public var semanticContent: SemanticContent
        public var semanticContentClearEOL: Bool
        public var pen: Style
        public var implicitHyperlinkCounter: UInt32
        public var charset: CharsetState
        /// 0: off; 1: ISO; 2: DEC.
        public var protectedMode: UInt8
        public var kittyKeyboardIndex: Int
        public var kittyKeyboardFlags: [UInt8]
        /// 0: none; 1: click events; 2: cursor keys.
        public var semanticClickKind: UInt8
        public var semanticClickValue: UInt8
        public var savedCursor: SavedCursor?
        public var cursorHyperlink: Hyperlink?
        /// The pages that hold the active area, oldest first. The screen is their
        /// last `TerminalState.rows` rows; any before those are already history.
        public var pages: [Page] = []
        /// The older pages, newest first.
        public var history: [Page] = []
    }

    /// A self-contained block of rows.
    public struct Page: Equatable, Sendable {
        public var columns: Int
        public var rows: [Row]
        /// Styles by ID; zero, the default, isn't here.
        public var styles: [UInt16: Style]
        /// Hyperlinks by ID; zero, none, isn't here.
        public var hyperlinks: [UInt16: Hyperlink]
    }

    public struct Row: Equatable, Sendable {
        /// This row's text continues on the next.
        public var wraps: Bool
        /// This row continues the previous one's text.
        public var isContinuation: Bool
        /// 0: none; 1: prompt; 2: prompt continuation.
        public var semanticPrompt: UInt8
        /// The row's cells up to its last that isn't default. The rest are default.
        public var cells: [Cell]
        /// The further scalars of multi-scalar graphemes, by column.
        public var graphemes: [Int: [UInt32]] = [:]
    }

    /// One cell, as the format's 64-bit word.
    public struct Cell: Equatable, Sendable {
        public var word: UInt64
        public init(word: UInt64) { self.word = word }

        public enum Width: UInt8, Equatable, Sendable {
            case narrow = 0
            case wide = 1
            case spacerTail = 2
            case spacerHead = 3
        }

        public enum Content: Equatable, Sendable {
            /// A Unicode scalar value; zero for an empty cell.
            case codepoint(UInt32)
            case backgroundPalette(UInt8)
            case backgroundRGB(RGB)
        }

        public var content: Content {
            let bits = UInt32((word >> 2) & 0xff_ffff)
            switch word & 3 {
            case 2: return .backgroundPalette(UInt8(bits & 0xff))
            case 3: return .backgroundRGB(RGB(red: UInt8(bits & 0xff), green: UInt8((bits >> 8) & 0xff), blue: UInt8(bits >> 16)))
            default:
                let isScalar = bits <= 0x10_ffff && !(bits >= 0xd800 && bits <= 0xdfff)
                return .codepoint(isScalar ? bits : 0xfffd)
            }
        }
        /// Whether the grapheme section has further scalars for this cell.
        public var hasGrapheme: Bool { word & 3 == 1 }
        public var styleID: UInt16 { UInt16((word >> 26) & 0xffff) }
        public var width: Width { Width(rawValue: UInt8((word >> 42) & 3)) ?? .narrow }
        public var isProtected: Bool { word & (1 << 44) != 0 }
        public var semanticContent: SemanticContent { SemanticContent(rawValue: UInt8((word >> 46) & 3)) ?? .output }
        public var hyperlinkID: UInt16 { UInt16(word >> 48) }
    }

    /// Puts a snapshot together from its decoder's events.
    private struct Builder {
        var terminal: TerminalState?
        var screens: [Screen] = []
        var continuation: [UInt8] = []

        mutating func take(_ event: GhosttySnapshotDecoder.Event) throws {
            switch event {
            case .terminal(let state): terminal = state
            case .screen(let screen): screens.append(screen)
            case .screenPage(let key, let page):
                if let index = screens.firstIndex(where: { $0.key == key }) { screens[index].pages.append(page) }
            case .ready(let bytes): continuation = bytes
            case .history: break
            case .historyPage(let key, let page):
                if let index = screens.firstIndex(where: { $0.key == key }) { screens[index].history.append(page) }
            case .finish: break
            }
        }

        func result() -> GhosttySnapshot? {
            guard let terminal else { return nil }
            return GhosttySnapshot(terminal: terminal, screens: screens, continuation: continuation)
        }
    }

    public init(terminal: TerminalState, screens: [Screen], continuation: [UInt8]) {
        self.terminal = terminal
        self.screens = screens
        self.continuation = continuation
    }
}

/// Reads a snapshot as it arrives, in pieces cut anywhere, one record at a time.
/// A client may show the screens at `.ready` and take the history as it comes.
public struct GhosttySnapshotDecoder: Sendable {
    public typealias Snapshot = GhosttySnapshot

    /// One record of a snapshot, in the order the format gives them.
    public enum Event: Equatable, Sendable {
        case terminal(Snapshot.TerminalState)
        /// A screen, without its pages.
        case screen(Snapshot.Screen)
        case screenPage(Snapshot.ScreenKey, Snapshot.Page)
        /// The terminal is complete but for its history. Holds the continuation.
        case ready([UInt8])
        case history(Snapshot.ScreenKey, pageCount: Int)
        case historyPage(Snapshot.ScreenKey, Snapshot.Page)
        case finish
    }

    /// The largest record this decoder holds before refusing it. A page is far smaller.
    public static let maximumRecordBytes: UInt32 = 256 << 20

    private enum Tag {
        static let terminal: UInt16 = 1, screen: UInt16 = 2, page: UInt16 = 3, history: UInt16 = 4,
                   ready: UInt16 = 5, finish: UInt16 = 6, continuation: UInt16 = 7
    }

    private enum Phase: Sendable {
        case envelope, terminal
        case screen(left: Int)
        case screenPages(Snapshot.ScreenKey, pages: Int, screensLeft: Int)
        case continuation, ready
        case history(left: Int)
        case historyPages(Snapshot.ScreenKey, pages: Int, screensLeft: Int)
        case finish, done
    }

    private var phase = Phase.envelope
    private var held: [UInt8] = []
    private var start = 0
    private var continuation: [UInt8] = []
    private var screenCount = 0

    public init() {}

    /// The FINISH record has been read.
    public var isFinished: Bool {
        if case .done = phase { return true }
        return false
    }

    /// The bytes after the snapshot's end, which are its container's. Taking them
    /// leaves none.
    public mutating func takeRemainder() -> [UInt8] {
        guard isFinished else { return [] }
        defer { held = []; start = 0 }
        return Array(held[start...])
    }

    /// How many bytes it's holding: a record not yet whole, or what followed the end.
    public var heldBytes: Int { held.count - start }

    /// Takes the next piece and returns the records it completed. After the end,
    /// what comes is kept for `takeRemainder`.
    public mutating func feed(_ bytes: [UInt8]) throws -> [Event] {
        held.append(contentsOf: bytes)
        var events: [Event] = []
        while !isFinished {
            guard let event = try next() else { break }
            if let event { events.append(event) }
        }
        if start > 0, start == held.count || start >= 1 << 16 {
            held.removeSubrange(0..<start)
            start = 0
        }
        return events
    }

    /// Reads one record if it's all there. Nil: it isn't. `.some(nil)`: it was read and tells nothing.
    private mutating func next() throws -> Event?? {
        if case .envelope = phase {
            let available = held.count - start
            let needed = Snapshot.magic.count + 2
            guard held[start...].prefix(Snapshot.magic.count).elementsEqual(Snapshot.magic.prefix(min(available, Snapshot.magic.count))) else {
                throw GhosttySnapshotError.notASnapshot
            }
            guard available >= needed else { return nil }
            let version = UInt16(held[start + 8]) | UInt16(held[start + 9]) << 8
            guard version == Snapshot.version else { throw GhosttySnapshotError.unsupportedVersion(version) }
            start += needed
            phase = .terminal
            return .some(nil)
        }
        guard held.count - start >= 10 else { return nil }
        let tag = UInt16(held[start]) | UInt16(held[start + 1]) << 8
        let length = UInt32(held[start + 2]) | UInt32(held[start + 3]) << 8 | UInt32(held[start + 4]) << 16 | UInt32(held[start + 5]) << 24
        let crc = UInt32(held[start + 6]) | UInt32(held[start + 7]) << 8 | UInt32(held[start + 8]) << 16 | UInt32(held[start + 9]) << 24
        guard tag == expectedTag else { throw GhosttySnapshotError.unexpectedRecord(tag: tag) }
        guard length <= Self.maximumRecordBytes else { throw GhosttySnapshotError.recordTooLarge(tag: tag, bytes: length) }
        let end = start + 10 + Int(length)
        guard held.count >= end else { return nil }
        // The CRC covers the tag, the length and the payload, but not itself.
        var check = CRC32C()
        check.update(held, start..<(start + 6))
        check.update(held, (start + 10)..<end)
        guard check.value == crc else { throw GhosttySnapshotError.checksumMismatch(tag: tag) }
        var reader = PayloadReader(bytes: held, at: start + 10, end: end, tag: tag)
        let event = try read(tag: tag, &reader, payload: (start + 10)..<end)
        start = end
        return .some(event)
    }

    private var expectedTag: UInt16 {
        switch phase {
        case .envelope, .terminal: return Tag.terminal
        case .screen: return Tag.screen
        case .screenPages, .historyPages: return Tag.page
        case .continuation: return Tag.continuation
        case .ready: return Tag.ready
        case .history: return Tag.history
        case .finish, .done: return Tag.finish
        }
    }

    private mutating func read(tag: UInt16, _ r: inout PayloadReader, payload: Range<Int>) throws -> Event? {
        switch phase {
        case .terminal:
            let state = try r.terminal()
            screenCount = state.screenCount
            phase = .screen(left: screenCount)
            return .terminal(state)
        case .screen(let left):
            let (screen, pages) = try r.screen()
            phase = pages > 0 ? .screenPages(screen.key, pages: pages, screensLeft: left - 1)
                : (left > 1 ? .screen(left: left - 1) : .continuation)
            return .screen(screen)
        case .screenPages(let key, let pages, let screensLeft):
            let page = try r.page()
            if pages > 1 {
                phase = .screenPages(key, pages: pages - 1, screensLeft: screensLeft)
            } else {
                phase = screensLeft > 0 ? .screen(left: screensLeft) : .continuation
            }
            return .screenPage(key, page)
        case .continuation:
            continuation = Array(held[payload])
            phase = .ready
            return nil
        case .ready:
            phase = .history(left: screenCount)
            return .ready(continuation)
        case .history(let left):
            let key = Snapshot.ScreenKey(rawValue: try r.u16()) ?? .primary
            let pages = Int(try r.u32())
            phase = pages > 0 ? .historyPages(key, pages: pages, screensLeft: left - 1)
                : (left > 1 ? .history(left: left - 1) : .finish)
            return .history(key, pageCount: pages)
        case .historyPages(let key, let pages, let screensLeft):
            let page = try r.page()
            if pages > 1 {
                phase = .historyPages(key, pages: pages - 1, screensLeft: screensLeft)
            } else {
                phase = screensLeft > 0 ? .history(left: screensLeft) : .finish
            }
            return .historyPage(key, page)
        case .finish:
            phase = .done
            return .finish
        case .envelope, .done:
            throw GhosttySnapshotError.unexpectedRecord(tag: tag)
        }
    }
}

extension GhosttySnapshotDecoder {
    /// A read of one record's payload. Running out of it means the record is
    /// malformed, since the framing has already said it's all here.
    fileprivate struct PayloadReader {
        let bytes: [UInt8]
        var at: Int
        let end: Int
        let tag: UInt16

        init(bytes: [UInt8], at: Int, end: Int, tag: UInt16) {
            self.bytes = bytes
            self.at = at
            self.end = end
            self.tag = tag
        }

        private func need(_ count: Int) throws {
            guard count >= 0, end - at >= count else { throw GhosttySnapshotError.malformed(tag: tag) }
        }
        mutating func u8() throws -> UInt8 {
            try need(1)
            defer { at += 1 }
            return bytes[at]
        }
        mutating func u16() throws -> UInt16 {
            try need(2)
            defer { at += 2 }
            return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
        }
        mutating func u32() throws -> UInt32 {
            try need(4)
            defer { at += 4 }
            return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        mutating func u64() throws -> UInt64 {
            let low = try u32()
            return UInt64(low) | UInt64(try u32()) << 32
        }
        mutating func flag() throws -> Bool { try u8() != 0 }
        /// Zero: nil; one: false; two: true.
        mutating func optionalFlag() throws -> Bool? {
            switch try u8() {
            case 1: return false
            case 2: return true
            default: return nil
            }
        }
        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            try need(count)
            defer { at += count }
            return bytes[at..<(at + count)]
        }
        mutating func string(_ count: Int) throws -> String {
            String(decoding: try take(count), as: UTF8.self)
        }
        mutating func rgb() throws -> Snapshot.RGB {
            let red = try u8(), green = try u8()
            return Snapshot.RGB(red: red, green: green, blue: try u8())
        }

        mutating func dynamicColor() throws -> Snapshot.DynamicColor {
            let hasDefault = try flag()
            let hostDefault = try rgb()
            let hasOverride = try flag()
            let override = try rgb()
            return Snapshot.DynamicColor(hostDefault: hasDefault ? hostDefault : nil, override: hasOverride ? override : nil)
        }

        mutating func terminal() throws -> Snapshot.TerminalState {
            let columns = Int(try u16()), rows = Int(try u16())
            guard columns > 0, rows > 0 else { throw GhosttySnapshotError.malformed(tag: tag) }
            let widthPixels = Int(try u32()), heightPixels = Int(try u32())
            let scrollTop = Int(try u16()), scrollBottom = Int(try u16()), scrollLeft = Int(try u16()), scrollRight = Int(try u16())
            let statusDisplay = try u8()
            let activeScreen = Snapshot.ScreenKey(rawValue: try u16()) ?? .primary
            let screenCount = Int(try u16())
            guard screenCount == 1 || screenCount == 2 else { throw GhosttySnapshotError.malformed(tag: tag) }
            let previous = try u32()
            let cursorIsDefault = try flag()
            let cursorDefaultStyle = Snapshot.CursorStyle(rawValue: try u8()) ?? .block
            let cursorDefaultBlink = try optionalFlag()
            let shellRedraw = try u8()
            let modifyOtherKeys2 = try flag()
            let mouseEvent = try u8(), mouseFormat = try u8()
            let mouseShiftCapture = try optionalFlag()
            let mouseShape = try u8()
            let passwordInput = try flag()
            let modes = Snapshot.Modes(rawValue: try u64())
            let savedModes = Snapshot.Modes(rawValue: try u64())
            let defaultModes = Snapshot.Modes(rawValue: try u64())
            let background = try dynamicColor(), foreground = try dynamicColor(), cursorColor = try dynamicColor()
            let maxScrollbackBytes = try u64(), maxScrollbackRows = try u64()

            var tabStops = [Bool](repeating: false, count: columns)
            let tabBytes = try take((columns + 7) / 8)
            for column in 0..<columns where tabBytes[tabBytes.startIndex + column / 8] & (1 << UInt8(column % 8)) != 0 {
                tabStops[column] = true
            }
            var palette: [Snapshot.RGB] = []
            palette.reserveCapacity(256)
            for _ in 0..<256 { palette.append(try rgb()) }
            let mask = try take(32)
            var overrides: [Int: Snapshot.RGB] = [:]
            for index in 0..<256 where mask[mask.startIndex + index / 8] & (1 << UInt8(index % 8)) != 0 {
                overrides[index] = try rgb()
            }
            let workingDirectory = try string(Int(try u32()))
            let title = try string(Int(try u32()))
            return Snapshot.TerminalState(
                columns: columns, rows: rows, widthPixels: widthPixels, heightPixels: heightPixels,
                scrollTop: scrollTop, scrollBottom: scrollBottom, scrollLeft: scrollLeft, scrollRight: scrollRight,
                statusDisplay: statusDisplay, activeScreen: activeScreen, screenCount: screenCount,
                previousCodepoint: previous == 0xffff_ffff ? nil : previous,
                cursorIsDefault: cursorIsDefault, cursorDefaultStyle: cursorDefaultStyle, cursorDefaultBlink: cursorDefaultBlink,
                shellRedraw: shellRedraw, modifyOtherKeys2: modifyOtherKeys2, mouseEvent: mouseEvent, mouseFormat: mouseFormat,
                mouseShiftCapture: mouseShiftCapture, mouseShape: mouseShape, passwordInput: passwordInput,
                modes: modes, savedModes: savedModes, defaultModes: defaultModes,
                background: background, foreground: foreground, cursorColor: cursorColor,
                maxScrollbackBytes: maxScrollbackBytes, maxScrollbackRows: maxScrollbackRows,
                tabStops: tabStops, originalPalette: palette, paletteOverrides: overrides,
                workingDirectory: workingDirectory, title: title)
        }

        mutating func color() throws -> Snapshot.Color {
            let kind = try u8(), first = try u8(), second = try u8(), third = try u8()
            switch kind {
            case 1: return .palette(first)
            case 2: return .rgb(Snapshot.RGB(red: first, green: second, blue: third))
            default: return .none
            }
        }

        mutating func style() throws -> Snapshot.Style {
            var style = Snapshot.Style()
            style.foreground = try color()
            style.background = try color()
            style.underlineColor = try color()
            let flags = try u16()
            _ = try u16()  // Reserved.
            style.bold = flags & (1 << 0) != 0
            style.italic = flags & (1 << 1) != 0
            style.faint = flags & (1 << 2) != 0
            style.blink = flags & (1 << 3) != 0
            style.inverse = flags & (1 << 4) != 0
            style.invisible = flags & (1 << 5) != 0
            style.strikethrough = flags & (1 << 6) != 0
            style.overline = flags & (1 << 7) != 0
            let underline = UInt8((flags >> 8) & 7)
            style.underline = underline <= 5 ? underline : 0
            return style
        }

        /// A hyperlink, or nil for its kind zero, none.
        mutating func hyperlink() throws -> Snapshot.Hyperlink? {
            switch try u8() {
            case 1:
                let id = try u32()
                return Snapshot.Hyperlink(id: .implicit(id), uri: try string(Int(try u32())))
            case 2:
                let id = try string(Int(try u32()))
                return Snapshot.Hyperlink(id: .explicit(id), uri: try string(Int(try u32())))
            default:
                return nil
            }
        }

        func charset(_ raw: UInt16) -> Snapshot.CharsetState {
            let single = UInt8((raw >> 12) & 7)
            return Snapshot.CharsetState(g: [UInt8(raw & 3), UInt8((raw >> 2) & 3), UInt8((raw >> 4) & 3), UInt8((raw >> 6) & 3)],
                                         gl: UInt8((raw >> 8) & 3), gr: UInt8((raw >> 10) & 3),
                                         singleShift: single >= 1 && single <= 4 ? single - 1 : nil)
        }

        /// A SCREEN record, and how many pages follow it.
        mutating func screen() throws -> (Snapshot.Screen, Int) {
            let key = Snapshot.ScreenKey(rawValue: try u16()) ?? .primary
            let pages = Int(try u16())
            let historyRows = try u64()
            let x = Int(try u16()), y = Int(try u16())
            let cursorStyle = Snapshot.CursorStyle(rawValue: try u8()) ?? .block
            let flags = try u8()
            let pen = try style()
            let implicit = try u32()
            let charsets = charset(try u16())
            let protectedMode = try u8()
            let index = Int(try u8() & 7)
            var keyboard: [UInt8] = []
            for _ in 0..<8 { keyboard.append(try u8() & 0x1f) }
            let clickKind = try u8(), clickValue = try u8()
            let hasSaved = try flag()
            var saved: Snapshot.SavedCursor?
            if hasSaved {
                let savedX = Int(try u16()), savedY = Int(try u16())
                let savedPen = try style()
                let savedFlags = try u8()
                saved = Snapshot.SavedCursor(x: savedX, y: savedY, pen: savedPen, isProtected: savedFlags & 1 != 0,
                                             pendingWrap: savedFlags & 2 != 0, origin: savedFlags & 4 != 0,
                                             charset: charset(try u16()))
            }
            let link = try hyperlink()
            let screen = Snapshot.Screen(
                key: key, historyRows: historyRows, cursorX: x, cursorY: y, cursorStyle: cursorStyle,
                pendingWrap: flags & 1 != 0, cursorProtected: flags & 2 != 0,
                semanticContent: Snapshot.SemanticContent(rawValue: (flags >> 2) & 3) ?? .output,
                semanticContentClearEOL: flags & 16 != 0, pen: pen, implicitHyperlinkCounter: implicit,
                charset: charsets, protectedMode: protectedMode, kittyKeyboardIndex: index, kittyKeyboardFlags: keyboard,
                semanticClickKind: clickKind, semanticClickValue: clickValue, savedCursor: saved, cursorHyperlink: link)
            return (screen, pages)
        }

        mutating func page() throws -> Snapshot.Page {
            let columns = Int(try u16()), rowCount = Int(try u16())
            guard columns > 0, rowCount > 0 else { throw GhosttySnapshotError.malformed(tag: tag) }
            let styleCount = Int(try u16()), linkCount = Int(try u16())
            _ = try take(12)  // Capacity hints.
            var styles: [UInt16: Snapshot.Style] = [:]
            for _ in 0..<styleCount {
                let id = try u16()
                styles[id] = try style()
            }
            var links: [UInt16: Snapshot.Hyperlink] = [:]
            for _ in 0..<linkCount {
                let id = try u16()
                links[id] = try hyperlink()
            }
            var rows: [Snapshot.Row] = []
            rows.reserveCapacity(rowCount)
            for _ in 0..<rowCount { rows.append(try row(columns: columns)) }
            // The grapheme section. Entries that don't fit are consumed and ignored.
            let entries = Int(try u32())
            for _ in 0..<entries {
                let row = Int(try u16()), column = Int(try u16()), count = Int(try u16())
                var scalars: [UInt32] = []
                scalars.reserveCapacity(count)
                for _ in 0..<count {
                    let scalar = try u32()
                    if scalar != 0, scalar <= 0x10_ffff, !(scalar >= 0xd800 && scalar <= 0xdfff) { scalars.append(scalar) }
                }
                guard row < rows.count, column < rows[row].cells.count, rows[row].cells[column].hasGrapheme,
                      rows[row].graphemes[column] == nil, !scalars.isEmpty else { continue }
                rows[row].graphemes[column] = scalars
            }
            return Snapshot.Page(columns: columns, rows: rows, styles: styles, hyperlinks: links)
        }

        private mutating func row(columns: Int) throws -> Snapshot.Row {
            let flags = try u8()
            let count = Int(try u16())
            guard count <= columns else { throw GhosttySnapshotError.malformed(tag: tag) }
            let width = 1 << Int((flags >> 4) & 3)
            try need(count * width)
            var cells: [Snapshot.Cell] = []
            cells.reserveCapacity(count)
            switch width {
            case 1:
                // Widths one and two hold the codepoint itself, which is bits 2-25 of the word.
                for offset in 0..<count { cells.append(Snapshot.Cell(word: UInt64(bytes[at + offset]) << 2)) }
            case 2:
                for offset in 0..<count {
                    let scalar = UInt64(bytes[at + offset * 2]) | UInt64(bytes[at + offset * 2 + 1]) << 8
                    cells.append(Snapshot.Cell(word: scalar << 2))
                }
            default:
                // Widths four and eight hold the word's low bytes unshifted.
                for offset in 0..<count {
                    var word: UInt64 = 0
                    for byte in 0..<width { word |= UInt64(bytes[at + offset * width + byte]) << UInt64(byte * 8) }
                    cells.append(Snapshot.Cell(word: word))
                }
            }
            at += count * width
            let prompt = (flags >> 2) & 3
            return Snapshot.Row(wraps: flags & 1 != 0, isContinuation: flags & 2 != 0, semanticPrompt: prompt <= 2 ? prompt : 0, cells: cells)
        }
    }
}

/// CRC-32C (Castagnoli), which the format's records carry.
struct CRC32C {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0x82f6_3b78 : crc >> 1 }
        return crc
    }
    private var state: UInt32 = 0xffff_ffff

    mutating func update(_ bytes: [UInt8], _ range: Range<Int>) {
        var crc = state
        let table = Self.table
        table.withUnsafeBufferPointer { table in
            bytes.withUnsafeBufferPointer { bytes in
                for index in range { crc = table[Int((crc ^ UInt32(bytes[index])) & 0xff)] ^ (crc >> 8) }
            }
        }
        state = crc
    }

    var value: UInt32 { ~state }
}

#endif
