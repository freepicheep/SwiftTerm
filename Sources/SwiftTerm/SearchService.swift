//
//  SearchService.swift
//  SwiftTerm
//
//  Ported and adapted from the xterm.js search addon infrastructure.
//

#if !SWIFTTERM_EMBEDDED
import Foundation

/// Finds text in a terminal's buffer, scrollback included, independent of any view.
///
/// `TerminalView` uses one for its find bar; hosts that draw the terminal themselves can
/// create their own and highlight what ``findAll(term:options:limit:)`` returns.
///
/// Search state is guarded by `terminal.terminalLock`; callers must hold it.
public final class SearchService {
    private let terminal: Terminal
    private let state = SearchState()
    private let lineCache: SearchLineCache
    private let engine: SearchEngine
    private var lastSelection: SearchSelection?

    /// The match the last ``findNext(term:options:)`` or ``findPrevious(term:options:)`` found.
    public private(set) var lastResult: SearchResult?

    public init (terminal: Terminal) {
        self.terminal = terminal
        let cache = SearchLineCache(terminal: terminal)
        self.lineCache = cache
        self.engine = SearchEngine(terminal: terminal, lineCache: cache)
    }

    /**
     * Invalidates the current search snapshot due to content or size changes.
     * The cache should be invalidated when either the content of the buffer or the buffer dimensions change
     * because the snapshot has direct mappings to buffer line and locations.
    */
    public func invalidate () {
        lineCache.invalidate()
        lastResult = nil
        lastSelection = nil
    }

    /// Forgets the search term, the last match and the cached lines.
    public func reset () {
        lineCache.invalidate()
        state.reset()
        lastResult = nil
        lastSelection = nil
    }

    /// Sets where the next ``findNext(term:options:)`` or ``findPrevious(term:options:)``
    /// continues from, for example the user's selection.
    public func updateLastSelection (_ selection: SearchSelection?) {
        lastSelection = selection
    }

    /// Finds the next match after the last one (or the selection), wrapping at the end.
    @discardableResult
    public func findNext (term: String, options: SearchOptions = SearchOptions()) -> SearchResult? {
        guard state.isValidSearchTerm(term) else {
            lastResult = nil
            lastSelection = nil
            state.reset()
            return nil
        }

        state.lastSearchOptions = options
        let result = engine.findNextWithSelection(term: term, searchOptions: options, cachedSearchTerm: state.cachedSearchTerm, previousSelection: lastSelection)
        state.cachedSearchTerm = term

        lastResult = result
        lastSelection = result.map { selection(for: $0) }
        return result
    }

    /// Finds the match before the last one (or the selection), wrapping at the start.
    @discardableResult
    public func findPrevious (term: String, options: SearchOptions = SearchOptions()) -> SearchResult? {
        guard state.isValidSearchTerm(term) else {
            lastResult = nil
            lastSelection = nil
            state.reset()
            return nil
        }

        state.lastSearchOptions = options
        let result = engine.findPreviousWithSelection(term: term, searchOptions: options, cachedSearchTerm: state.cachedSearchTerm, previousSelection: lastSelection)
        state.cachedSearchTerm = term

        lastResult = result
        lastSelection = result.map { selection(for: $0) }
        return result
    }

    /// Every match from the top of the scrollback down, at most `limit` of them.
    ///
    /// Lines are cached between calls; call ``invalidate()`` when the buffer changes.
    public func findAll (term: String, options: SearchOptions = SearchOptions(), limit: Int = 1000) -> [SearchResult] {
        guard state.isValidSearchTerm(term) else {
            return []
        }

        lineCache.initLinesCache()

        var results: [SearchResult] = []
        var prevResult: SearchResult?
        var result = engine.find(term: term, startRow: 0, startCol: 0, searchOptions: options)

        while let match = result {
            if results.count >= limit {
                break
            }
            if let prevResult, prevResult.row == match.row && prevResult.col == match.col {
                break
            }
            results.append(match)
            prevResult = match

            let nextPosition = advancePosition(from: Position(col: match.col, row: match.row), by: max(match.size, 1))
            result = engine.find(term: term, startRow: nextPosition.row, startCol: nextPosition.col, searchOptions: options)
        }

        return results
    }

    /// The cells `result` covers, its end exclusive.
    public func selectionRange (for result: SearchResult) -> (start: Position, end: Position) {
        let start = Position(col: result.col, row: result.row)
        let end = advancePosition(from: start, by: max(result.size, 0))
        return (start, end)
    }

    private func selection (for result: SearchResult) -> SearchSelection {
        let range = selectionRange(for: result)
        return SearchSelection(start: range.start, end: range.end)
    }

    private func advancePosition (from position: Position, by cells: Int) -> Position {
        guard cells > 0 else {
            return position
        }
        let cols = max(terminal.cols, 1)
        let linearStart = position.row * cols + position.col
        let linearEnd = linearStart + cells
        let newRow = linearEnd / cols
        let newCol = linearEnd % cols
        return Position(col: newCol, row: newRow)
    }
}

#endif // !SWIFTTERM_EMBEDDED
