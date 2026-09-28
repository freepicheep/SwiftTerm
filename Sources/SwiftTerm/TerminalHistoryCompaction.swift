//
//  TerminalHistoryCompaction.swift
//  SwiftTerm
//
//  The public API for moving cold scrollback into compact storage.
//

/// How much work ``Terminal/compactHistory(_:)`` does before returning.
public enum HistoryCompactionMode: Sendable {
    /// One bounded step: at most a few hundred rows moved, a few thousand
    /// inspected. Suitable for an idle timer in an interactive terminal.
    case incremental
    /// Everything that can be moved now. Can take milliseconds on a long
    /// scrollback, so avoid it while the user is interacting.
    case full
}

/// What ``Terminal/compactHistory(_:)`` found.
public enum HistoryCompactionResult: Sendable {
    /// More work remains; call again (for example after a short delay).
    case pending
    /// Nothing left to move until ``Terminal/historyActivity`` changes.
    case complete
}

/// Memory held by a buffer's history, from ``Terminal/historyStorage``.
public struct HistoryStorage: Sendable, Equatable {
    /// Lines held as full line objects in the line ring, screen included.
    public var residentRows: Int
    /// Scrollback rows held in compact cold storage.
    public var coldRows: Int
    /// Bytes of cold storage, not counting allocator rounding.
    public var coldBytes: Int
}

extension Terminal {
    /// Changes whenever the normal screen's history may have new work for
    /// ``compactHistory(_:)``: output scrolled lines into history, the
    /// viewport moved, or cold rows were read back. Compare it with the
    /// value you saw last to decide whether to schedule compaction; it is a
    /// change token, not an ordering.
    public var historyActivity: UInt64 {
        normalBuffer.historyActivity
    }

    /// Moves cold scrollback rows of the normal screen out of the line ring
    /// into compact storage.
    ///
    /// A scrollback row normally costs a full line object: 8 bytes for every
    /// column plus about 180 bytes of objects, whatever it holds. Cold
    /// storage keeps a row's cells up to the last non-blank one, with the
    /// style bits shared by runs of cells (see `HistoryRowCodec`), and its line
    /// state in 32 bytes; rows are grouped into chunks, so there is no
    /// allocation per row. An 80-column row of plain text drops from about
    /// 820 bytes of heap to about 140.
    ///
    /// Nothing changes for readers: reading a cold row (drawing it, selecting
    /// it, ``getLine(row:)``, ``getScrollInvariantLine(row:)``) moves it back
    /// into the ring first. Search and selection read cold rows through a
    /// temporary copy, without moving them back. Rows in the viewport, rows
    /// with images or semantic prompt marks, and rows that something outside
    /// the terminal holds a reference to are never moved.
    ///
    /// Moving rows costs CPU, so nothing happens during output: the host
    /// decides when. The model is Ghostty's cold page compression: watch
    /// ``historyActivity``, and once output has been quiet for a while (for
    /// example a second), call this with `.incremental` until it returns
    /// `.complete`, a few milliseconds apart. Call it with the same
    /// synchronization you use for ``feed(byteArray:)``.
    @discardableResult
    public func compactHistory(_ mode: HistoryCompactionMode = .incremental) -> HistoryCompactionResult {
        switch mode {
        case .incremental:
            return normalBuffer.compactHistory(maxRows: 256, maxInspected: 4096)
        case .full:
            while normalBuffer.compactHistory(maxRows: 1024, maxInspected: .max) == .pending {}
            return .complete
        }
    }

    /// Moves every cold row of the normal screen back into the line ring.
    public func restoreHistory() {
        normalBuffer.restoreHistory()
    }

    /// How the normal screen's history is currently held.
    public var historyStorage: HistoryStorage {
        let buffer = normalBuffer
        let cold = buffer.coldRowCount
        return HistoryStorage(residentRows: buffer.lines.count - cold, coldRows: cold,
                              coldBytes: buffer.coldHistory.byteCount)
    }
}

extension Buffer {
    /// Like ``getScrollInvariantLine(row:)``, for reading only: a row in cold
    /// history comes back as a temporary copy instead of being moved back
    /// into the ring, so reading all of history (to serialize it, say) does
    /// not undo compaction. Don't keep the line or change it.
    public func readScrollInvariantLine(row: Int) -> BufferLine? {
        if row < linesTop || row >= lines.count + linesTop {
            return nil
        }
        return readOnlyLine(row - linesTop)
    }
}
