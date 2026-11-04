//
//  GhosttySnapshotRestore.swift
//  SwiftTerm
//
//  Loads a Ghostty snapshot into a terminal. Cells go straight into the buffers.
//  Modes and the like go through the parser as the sequences that set them, so
//  whatever else those do here (the erase cell, the host's mouse state) happens
//  as it would have.
//

#if !SWIFTTERM_EMBEDDED
import Foundation

/// How `Terminal.restore(from:options:)` treats what belongs to the host.
public struct GhosttySnapshotRestoreOptions: Sendable {
    /// Whether to take the snapshot's default colors and palette too, rather than
    /// only the colors programs set. Turn this off when this terminal has a theme
    /// of its own that should stay.
    public var hostColors: Bool

    public init(hostColors: Bool = true) {
        self.hostColors = hostColors
    }
}

extension Terminal {
    /// Replaces this terminal's state with `snapshot`'s, ready for the output that
    /// follows it: the grid size, the scrollback (up to this terminal's limit), the
    /// screens, the modes, the cursor and the rest. The caller synchronizes via
    /// `terminalLock`, as for `feed`.
    ///
    /// Nothing is sent to the host, whatever modes this turns on. What SwiftTerm has
    /// no place for is left out: overline, the GR charset slot, the mouse pointer shape,
    /// the status line, the password-input flag, the shell-redraw policy, and a pending
    /// wrap on the saved cursor. The format doesn't carry images.
    public func restore(from snapshot: GhosttySnapshot, options: GhosttySnapshotRestoreOptions = .init()) {
        let state = snapshot.terminal
        let delegate = tdel
        let oldCols = cols, oldRows = rows
        // Enabling a report would send it; the host hears about the rest below.
        tdel = nil
        feed(byteArray: [0x18])  // Ends any sequence the last output left unfinished.
        resetToInitialState()
        resize(cols: state.columns, rows: state.rows)

        let primary = snapshot.screens.first { $0.key == .primary }
        let alternate = snapshot.screens.first { $0.key == .alternate }
        let alternateIsActive = state.activeScreen == .alternate && alternate != nil

        for buffer in [normalBuffer, altBuffer] {
            buffer.tabStops = (0..<max(cols, 1)).map { $0 < state.tabStops.count && state.tabStops[$0] }
        }
        restoreModes(state)
        restoreColors(state, options)

        var links: [GhosttySnapshot.Hyperlink: TinyAtom] = [:]
        if let primary {
            restoreContents(of: primary, into: normalBuffer, links: &links)
            restoreKeyboard(primary)
        }
        if let alternate {
            feed(text: "\u{1b}[?47h")
            restoreContents(of: alternate, into: altBuffer, links: &links)
            restoreKeyboard(alternate)
            if !alternateIsActive { feed(text: "\u{1b}[?47l") }
        }
        if let screen = alternateIsActive ? alternate : primary {
            restoreRegions(state)
            restorePen(of: screen)
            restoreCursor(of: screen)
        }
        if !state.cursorIsDefault, let screen = alternateIsActive ? alternate : primary {
            let blinks = state.modes.contains(GhosttySnapshot.modeRegistry[12])
            feed(text: "\u{1b}[\(Self.cursorStyleParameter(screen.cursorStyle, blinks: blinks)) q")
        }
        if state.modifyOtherKeys2 { feed(text: "\u{1b}[>4;2m") }
        if let capture = state.mouseShiftCapture { feed(text: "\u{1b}[>\(capture ? 1 : 0)s") }
        if !state.workingDirectory.isEmpty { hostCurrentDirectory = state.workingDirectory }

        tdel = delegate
        if cols != oldCols || rows != oldRows { delegate?.sizeChanged(source: self) }
        if !state.title.isEmpty { setTitle(text: state.title) }
        if hostCurrentDirectory != nil { delegate?.hostCurrentDirectoryUpdated(source: self) }
        delegate?.colorChanged(source: self, idx: nil)
        // Under these flags, as when the colors change: a delegate that sets them back
        // would otherwise make the terminal derive its palette over the restored one.
        settingFgColor = true
        delegate?.setForegroundColor(source: self, color: foregroundColor)
        settingFgColor = false
        settingBgColor = true
        delegate?.setBackgroundColor(source: self, color: backgroundColor)
        settingBgColor = false
        settingCursorColor = true
        delegate?.setCursorColor(source: self, color: cursorColor)
        settingCursorColor = false
        delegate?.mouseModeChanged(source: self)
        delegate?.cursorStyleChanged(source: self, newStyle: self.options.cursorStyle)
        if alternateIsActive { delegate?.bufferActivated(source: self) }
        if cursorHidden { delegate?.hideCursor(source: self) } else { delegate?.showCursor(source: self) }

        if !snapshot.continuation.isEmpty { feed(byteArray: snapshot.continuation) }
        updateFullScreen()
    }

    private static func cursorStyleParameter(_ style: GhosttySnapshot.CursorStyle, blinks: Bool) -> Int {
        switch style {
        case .block, .blockHollow: return blinks ? 1 : 2
        case .underline: return blinks ? 3 : 4
        case .bar: return blinks ? 5 : 6
        }
    }

    // MARK: Modes

    /// Modes this doesn't set: the alternate-screen ones, since which screen is
    /// active is restored apart; the column mode, since the size is; the cursor save,
    /// which is an action; and synchronized output, since nothing is sure to end it.
    private static let modesLeftAlone: Set<Int> = [3, 47, 1047, 1048, 1049, 2026]

    private func restoreModes(_ state: GhosttySnapshot.TerminalState) {
        // What XTSAVE holds: only saved values that aren't the default make a
        // difference, because restoring a mode nothing saved gives its default.
        var saved: [Int] = []
        var wanted: [(GhosttySnapshot.Mode, Bool)] = []
        for mode in GhosttySnapshot.modeRegistry where !mode.isANSI && !Self.modesLeftAlone.contains(mode.number) {
            let value = state.savedModes.contains(mode)
            guard value != state.defaultModes.contains(mode) else { continue }
            saved.append(mode.number)
            wanted.append((mode, value))
        }
        if !saved.isEmpty {
            setModes(wanted)
            feed(text: "\u{1b}[?" + saved.map(String.init).joined(separator: ";") + "s")
        }
        setModes(GhosttySnapshot.modeRegistry.filter { !Self.modesLeftAlone.contains($0.number) || $0.isANSI }
            .map { ($0, state.modes.contains($0)) })
    }

    /// Sets each mode this terminal knows and has at another value. Resets go first,
    /// so that resetting one mouse mode doesn't undo setting another.
    private func setModes(_ modes: [(GhosttySnapshot.Mode, Bool)]) {
        var sets = "", resets = ""
        for (mode, value) in modes {
            // DECRQM's answer: 1 set, 2 reset; anything else can't be changed.
            let now = modeReportValue(mode.number, decPrivate: !mode.isANSI)
            guard now == 1 || now == 2, (now == 1) != value else { continue }
            let sequence = "\u{1b}[" + (mode.isANSI ? "" : "?") + String(mode.number) + (value ? "h" : "l")
            if value { sets += sequence } else { resets += sequence }
        }
        feed(text: resets + sets)
    }

    private func restoreRegions(_ state: GhosttySnapshot.TerminalState) {
        if state.scrollTop != 0 || state.scrollBottom != rows - 1 {
            feed(text: "\u{1b}[\(state.scrollTop + 1);\(state.scrollBottom + 1)r")
        }
        if marginMode, state.scrollLeft != 0 || state.scrollRight != cols - 1 {
            feed(text: "\u{1b}[\(state.scrollLeft + 1);\(state.scrollRight + 1)s")
        }
    }

    // MARK: Colors

    private static func color(_ rgb: GhosttySnapshot.RGB) -> Color {
        Color(red8: UInt16(rgb.red), green8: UInt16(rgb.green), blue8: UInt16(rgb.blue))
    }

    private func restoreColors(_ state: GhosttySnapshot.TerminalState, _ options: GhosttySnapshotRestoreOptions) {
        func chosen(_ color: GhosttySnapshot.DynamicColor) -> GhosttySnapshot.RGB? {
            options.hostColors ? color.effective : color.override
        }
        if let rgb = chosen(state.foreground) { foregroundColor = Self.color(rgb) }
        if let rgb = chosen(state.background) { backgroundColor = Self.color(rgb) }
        if let rgb = chosen(state.cursorColor) { cursorColor = Self.color(rgb) }
        // After those: setting them can derive the palette afresh.
        if options.hostColors {
            for (index, rgb) in state.originalPalette.enumerated() where index < ansiColors.count {
                defaultAnsiColors[index] = Self.color(rgb)
                ansiColors[index] = Self.color(rgb)
            }
        }
        for (index, rgb) in state.paletteOverrides where index < ansiColors.count {
            ansiColors[index] = Self.color(rgb)
        }
    }

    // MARK: Attributes

    static func attribute(_ style: GhosttySnapshot.Style) -> Attribute {
        func color(_ color: GhosttySnapshot.Color) -> Attribute.Color? {
            switch color {
            case .none: return nil
            case .palette(let index): return .ansi256(code: index)
            case .rgb(let rgb): return .trueColor(red: rgb.red, green: rgb.green, blue: rgb.blue)
            }
        }
        var flags: CharacterStyle = .none
        if style.bold { flags.insert(.bold) }
        if style.italic { flags.insert(.italic) }
        if style.faint { flags.insert(.dim) }
        if style.blink { flags.insert(.blink) }
        if style.inverse { flags.insert(.inverse) }
        if style.invisible { flags.insert(.invisible) }
        if style.strikethrough { flags.insert(.crossedOut) }
        if style.underline != 0 { flags.insert(.underline) }
        return Attribute(fg: color(style.foreground) ?? CharData.defaultAttr.fg,
                         bg: color(style.background) ?? CharData.defaultAttr.bg,
                         style: flags,
                         underlineStyle: UnderlineStyle(rawValue: style.underline) ?? .none,
                         underlineColor: color(style.underlineColor))
    }

    // MARK: Screens

    /// A page's styles and links in this terminal's terms.
    private struct PageCells {
        var attributes: [UInt16: Attribute] = [:]
        var payloads: [UInt16: UInt16] = [:]
    }

    private func pageCells(_ page: GhosttySnapshot.Page, links: inout [GhosttySnapshot.Hyperlink: TinyAtom]) -> PageCells {
        var cells = PageCells()
        for (id, style) in page.styles { cells.attributes[id] = Self.attribute(style) }
        guard enableOsc8Hyperlinks else { return cells }
        for (id, link) in page.hyperlinks {
            if let atom = links[link] ?? makeLinkPayload(link) {
                links[link] = atom
                cells.payloads[id] = atom.code
            }
        }
        return cells
    }

    /// A link as OSC 8 would have stored it: `params;uri`.
    private func makeLinkPayload(_ link: GhosttySnapshot.Hyperlink) -> TinyAtom? {
        makePayload(value: Self.oscLinkText(link))
    }

    private static func oscLinkText(_ link: GhosttySnapshot.Hyperlink) -> String {
        if case .explicit(let id) = link.id, !id.isEmpty { return "id=" + id + ";" + link.uri }
        return ";" + link.uri
    }

    private func restoreContents(of screen: GhosttySnapshot.Screen, into buffer: Buffer,
                                 links: inout [GhosttySnapshot.Hyperlink: TinyAtom]) {
        buffer.clear()
        let pages = buffer.hasScrollback ? screen.history.reversed() + screen.pages : screen.pages
        let columns = buffer.cols
        var skip = 0
        if pages.allSatisfy({ $0.columns == columns }) {
            skip = max(0, pages.reduce(0) { $0 + $1.rows.count } - buffer.lines.maxLength)
        }
        var lines: [BufferLine] = []
        var groups: UInt64 = 0
        var logical: [CharData] = []
        var logicalContinues = false
        for page in pages {
            let cells = pageCells(page, links: &links)
            for row in page.rows {
                if skip > 0 {
                    skip -= 1
                    continue
                }
                if page.columns == columns {
                    lines.append(makeLine(row, cells, in: buffer, groups: &groups))
                } else {
                    // Another width: the row's text is laid out again at this one.
                    logical += Self.charData(row, cells, width: page.columns, fullWidth: row.wraps)
                    if row.wraps {
                        logicalContinues = true
                    } else {
                        Self.layOut(logical, in: buffer, onto: &lines)
                        logical.removeAll(keepingCapacity: true)
                        logicalContinues = false
                    }
                }
            }
        }
        if logicalContinues { Self.layOut(logical, in: buffer, onto: &lines) }
        let kept = lines.count > buffer.lines.maxLength ? Array(lines.suffix(buffer.lines.maxLength)) : lines
        buffer.restore(lines: kept, semanticGroups: groups)
        buffer.savedX = 0
        buffer.savedY = 0
        if let saved = screen.savedCursor {
            buffer.savedX = min(saved.x, max(cols - 1, 0))
            buffer.savedY = min(saved.y, max(rows - 1, 0))
            buffer.savedAttr = Self.attribute(saved.pen)
            buffer.savedCharset = Self.table(saved.charset)
            buffer.savedOriginMode = saved.origin
            buffer.savedCharacterProtection = saved.isProtected
        }
        buffer.semanticContent = Self.semanticContent(screen.semanticContent)
        switch screen.semanticClickKind {
        case 1: buffer.semanticClickMode = screen.semanticClickValue == 0 ? .clickEventsAbsolute : .clickEventsRelative
        case 2:
            let modes: [SemanticPromptCursorClickMode] = [.line, .multiple, .conservativeVertical, .smartVertical]
            buffer.semanticClickMode = .cursorKeys(modes[min(Int(screen.semanticClickValue), modes.count - 1)])
        default: buffer.semanticClickMode = .none
        }
    }

    private static func semanticContent(_ content: GhosttySnapshot.SemanticContent) -> SemanticContent {
        switch content {
        // Ghostty's default, which says no more than SwiftTerm's `.none` does.
        case .output: return .none
        case .input: return .input
        case .prompt: return .prompt(.initial)
        }
    }

    /// One row's cells, keeping to the rule that a wide cell's tail follows it. Without
    /// `fullWidth`, it stops after the last cell the row has.
    private static func charData(_ row: GhosttySnapshot.Row, _ page: PageCells, width: Int, fullWidth: Bool) -> [CharData] {
        var cells: [CharData] = []
        cells.reserveCapacity(fullWidth ? width : row.cells.count)
        for (column, cell) in row.cells.enumerated() {
            cells.append(charData(cell, column: column, row: row, page))
        }
        if fullWidth { while cells.count < width { cells.append(CharData.Null) } }
        return cells
    }

    private static func charData(_ cell: GhosttySnapshot.Cell, column: Int, row: GhosttySnapshot.Row, _ page: PageCells) -> CharData {
        var attribute = page.attributes[cell.styleID] ?? CharData.defaultAttr
        var code: UInt32 = 0
        switch cell.content {
        case .codepoint(let scalar): code = scalar
        case .backgroundPalette(let index):
            attribute = Attribute(fg: attribute.fg, bg: .ansi256(code: index), style: attribute.style,
                                  underlineStyle: attribute.underlineStyle, underlineColor: attribute.underlineColor)
        case .backgroundRGB(let rgb):
            attribute = Attribute(fg: attribute.fg, bg: .trueColor(red: rgb.red, green: rgb.green, blue: rgb.blue),
                                  style: attribute.style, underlineStyle: attribute.underlineStyle,
                                  underlineColor: attribute.underlineColor)
        }
        var scalars: [UInt32]?
        if let more = row.graphemes[column], code != 0 { scalars = [code] + more }
        let size: Int8
        switch cell.width {
        case .narrow: size = 1
        case .wide: size = 2
        case .spacerTail, .spacerHead: size = 0
        }
        var semantic = semanticContent(cell.semanticContent)
        if semantic == .prompt(.initial), row.semanticPrompt == 2 { semantic = .prompt(.secondary) }
        return CharData(attribute: attribute, code: Int32(code), graphemeScalarValues: scalars, size: size,
                        widthStateCode: cell.width.rawValue, payloadCode: page.payloads[cell.hyperlinkID] ?? 0,
                        semanticContent: semantic, isProtected: cell.isProtected)
    }

    private func makeLine(_ row: GhosttySnapshot.Row, _ page: PageCells, in buffer: Buffer, groups: inout UInt64) -> BufferLine {
        let line = buffer.getBlankLine(attribute: CharData.defaultAttr, isWrapped: row.isContinuation)
        let columns = buffer.cols
        var column = 0
        let count = min(row.cells.count, columns)
        var promptColumn: Int?
        while column < count {
            let cell = row.cells[column]
            if cell.word == 0 {
                column += 1
                continue
            }
            var data = Self.charData(cell, column: column, row: row, page)
            if cell.semanticContent == .prompt, promptColumn == nil { promptColumn = column }
            switch cell.width {
            case .wide:
                guard column + 1 < columns else {
                    // No room for its tail: a blank, as a program couldn't have written it.
                    data = CharData(attribute: data.attribute)
                    line[column] = data
                    column += 1
                    continue
                }
                line[column] = data
                // Its tail, whatever the next word says.
                let tail = CharData(attribute: data.attribute, code: 0, graphemeScalarValues: nil, size: 0, widthStateCode: 2,
                                payloadCode: data.payload.code, semanticContent: data.semanticContent, isProtected: data.isProtected)
                line[column + 1] = tail
                column += 2
                continue
            case .spacerTail, .spacerHead:
                // A tail with no head (a head takes its own, above), or the gap before a
                // wide character that wrapped, which SwiftTerm leaves as a plain blank.
                data = CharData(attribute: data.attribute)
            case .narrow:
                break
            }
            line[column] = data
            column += 1
        }
        if row.semanticPrompt != 0 {
            groups += 1
            line.setSemanticMark(kind: row.semanticPrompt == 2 ? .secondary : .initial, column: promptColumn ?? 0, group: groups)
        }
        return line
    }

    /// Lays one logical line, from a page of another width, out at this buffer's width.
    private static func layOut(_ cells: [CharData], in buffer: Buffer, onto lines: inout [BufferLine]) {
        let columns = buffer.cols
        var cells = cells
        // What the wrapped rows were padded with isn't text.
        while let last = cells.last, last.code == 0, last.width == 1, !last.hasPayload, last.attribute == CharData.defaultAttr {
            cells.removeLast()
        }
        var at = 0
        var continuation = false
        repeat {
            let line = buffer.getBlankLine(attribute: CharData.defaultAttr, isWrapped: continuation)
            var column = 0
            while column < columns, at < cells.count {
                let cell = cells[at]
                // A wide cell that won't fit starts the next row.
                if cell.width == 2, column == columns - 1 { break }
                line[column] = cell
                column += 1
                at += 1
            }
            lines.append(line)
            continuation = true
        } while at < cells.count
    }

    // MARK: The rest of a screen

    private func restoreKeyboard(_ screen: GhosttySnapshot.Screen) {
        guard screen.kittyKeyboardFlags.contains(where: { $0 != 0 }) else { return }
        // A ring whose newest entry is the one at the index, so in order from the next.
        var sequence = ""
        for offset in 1...8 {
            let entry = screen.kittyKeyboardFlags[(screen.kittyKeyboardIndex + offset) % 8]
            sequence += "\u{1b}[>\(entry)u"
        }
        feed(text: sequence)
    }

    private static func table(_ charset: GhosttySnapshot.CharsetState) -> [UInt8: String]? {
        let designated = charset.g[Int(min(charset.gl, 3))]
        return designated == 2 ? CharSets.all[UInt8(ascii: "A")] : designated == 3 ? CharSets.all[UInt8(ascii: "0")] : CharSets.defaultCharset
    }

    private func restorePen(of screen: GhosttySnapshot.Screen) {
        feed(text: Self.attribute(screen.pen).sgrSequence)
        if let link = screen.cursorHyperlink, enableOsc8Hyperlinks {
            let text = Self.oscLinkText(link)
            feed(text: "\u{1b}]8;" + text + "\u{1b}\\")
        }
        var sequence = ""
        for slot in 0..<4 {
            let introducer = ["(", ")", "*", "+"][slot]
            let name: String
            switch screen.charset.g[slot] {
            case 2: name = "A"
            case 3: name = "0"
            default: name = "B"
            }
            if name != "B" { sequence += "\u{1b}" + introducer + name }
        }
        // SO, LS2 and LS3 pick what GL holds. SwiftTerm has no GR to restore.
        switch screen.charset.gl {
        case 1: sequence += "\u{0e}"
        case 2: sequence += "\u{1b}n"
        case 3: sequence += "\u{1b}o"
        default: break
        }
        switch screen.protectedMode {
        case 1 where screen.cursorProtected: sequence += "\u{1b}V"
        case 2 where screen.cursorProtected: sequence += "\u{1b}[1\"q"
        default: break
        }
        if let shift = screen.charset.singleShift {
            if shift == 2 { sequence += "\u{1b}N" } else if shift == 3 { sequence += "\u{1b}O" }
        }
        if !sequence.isEmpty { feed(text: sequence) }
    }

    /// Last of all, because setting modes and regions homes the cursor. A pending wrap
    /// is the cursor just past the last column.
    private func restoreCursor(of screen: GhosttySnapshot.Screen) {
        let buffer = self.buffer
        buffer.y = min(screen.cursorY, max(rows - 1, 0))
        buffer.x = screen.pendingWrap ? cols : min(screen.cursorX, max(cols - 1, 0))
    }
}

#endif
