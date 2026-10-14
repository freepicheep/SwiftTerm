# Search

SwiftTerm includes built-in search support for `TerminalView` and a macOS find bar that integrates
with the standard **Edit > Find** menu. You can also build your own search UI by calling the
search helpers directly.

## Built-in macOS Find Bar

When running on macOS, `TerminalView` provides a floating find bar that supports:

- `Cmd-F` to open
- Next/Previous navigation
- Use Selection for Find
- Case sensitive, regex, and whole-word options

## Custom Search UI

If you want your own UI (for example, a custom find bar, a toolbar item, or a command palette),
call the `TerminalView` helpers:

```swift
terminalView.findNext("term")
terminalView.findPrevious("term", options: SearchOptions(caseSensitive: true))
terminalView.clearSearch()
```

You can enable regular expressions and whole-word matching via `SearchOptions`.

## Searching Without a View

Hosts that render the terminal themselves (a game engine, a headless tool) can use
``SearchService`` directly against a ``Terminal``. Results are buffer positions: `row`
indexes the display buffer's lines, scrollback included, as ``SelectionService`` does, and
`size` counts cells, so a match can wrap onto the next rows.

```swift
let search = SearchService(terminal: terminal)
terminal.terminalLock.withLock {
    // Every match, top to bottom, to highlight.
    let matches = search.findAll(term: "error", limit: 1000)
    // Or step through them one at a time.
    let next = search.findNext(term: "error")
    let cells = next.map { search.selectionRange(for: $0) }
}
```

The service caches each line's text between calls; call `invalidate()` after the buffer
changes (new output, a resize) so the next search reads it again.
