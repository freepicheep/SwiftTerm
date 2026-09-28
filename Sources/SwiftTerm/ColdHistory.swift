//
//  ColdHistory.swift
//  SwiftTerm
//
//  Scrollback rows that nobody is looking at, kept outside the line ring in a
//  compact encoding and restored when they are read again.
//

#if !SWIFTTERM_EMBEDDED
import Foundation
#endif

/// The line state stored in front of each row's encoded cells.
struct ColdRowHeader {
    var width: UInt16
    var count: UInt16
    var runCount: UInt16
    var contentWidth: UInt8
    var renderMode: UInt8
    var bidiState: BidiPresentationState
    var tail: UInt64

    /// Bytes a header occupies in the payload. Row payloads start on 8-byte
    /// boundaries, and so do the encoded cells after the header.
    static let size = (MemoryLayout<ColdRowHeader>.size + 7) & ~7

    var layout: HistoryRowLayout {
        HistoryRowLayout(count: Int(count), runCount: Int(runCount), contentWidth: Int(contentWidth))
    }

    static func renderModeCode(_ mode: BufferLine.RenderLineMode) -> UInt8 {
        switch mode {
        case .single: return 0
        case .doubleWidth: return 1
        case .doubledTop: return 2
        case .doubledDown: return 3
        }
    }

    var lineRenderMode: BufferLine.RenderLineMode {
        switch renderMode {
        case 1: return .doubleWidth
        case 2: return .doubledTop
        case 3: return .doubledDown
        default: return .single
        }
    }
}

/// The rows moved out of the ring in one compaction step, in key order.
///
/// Everything lives in one allocation of exactly the size needed, with no
/// object or allocation per row. It starts with what lookups need, one entry
/// per row and never compressed:
///
/// - the key, as a 32-bit offset from the chunk's first key,
/// - the byte offset of the row's payload,
/// - flags: soft-wrapped, dead.
///
/// Then the payload: for each row, a ``ColdRowHeader`` and the cells encoded
/// by ``HistoryRowCodec``.
///
/// A restored row is marked dead; the chunk is released once all of its rows
/// are dead, either restored or dropped off the top of the scrollback.
final class HistoryChunk {
    static let wrappedFlag: UInt8 = 1 << 0
    static let deadFlag: UInt8 = 1 << 1

    let firstKey: Int
    let lastKey: Int
    let rowCount: Int
    private(set) var liveCount: Int
    /// Rows before this index are known to be dead. Dropping proceeds from the
    /// oldest row, so this lets it resume without rescanning.
    private var dropCursor = 0

    private let storage: UnsafeMutableRawPointer
    private let storageSize: Int
    private let payloadStart: Int

    private var keyDeltas: UnsafeMutablePointer<UInt32> {
        storage.assumingMemoryBound(to: UInt32.self)
    }
    private var payloadOffsets: UnsafeMutablePointer<UInt32> {
        (storage + rowCount * 4).assumingMemoryBound(to: UInt32.self)
    }
    private var flags: UnsafeMutablePointer<UInt8> {
        (storage + rowCount * 8).assumingMemoryBound(to: UInt8.self)
    }
    private var payload: UnsafeMutableRawPointer { storage + payloadStart }

    fileprivate init(keys: [Int], payloadOffsets offsets: [Int], flags rowFlags: [UInt8],
                     payloadSize: Int, writePayload: (UnsafeMutableRawPointer) -> Void) {
        rowCount = keys.count
        firstKey = keys[0]
        lastKey = keys[keys.count - 1]
        liveCount = rowCount
        payloadStart = (rowCount * 9 + 7) & ~7
        storageSize = payloadStart + payloadSize
        storage = .allocate(byteCount: storageSize, alignment: 8)
        storage.bindMemory(to: UInt32.self, capacity: rowCount * 2)
        for row in 0..<rowCount {
            keyDeltas[row] = UInt32(keys[row] - firstKey)
            payloadOffsets[row] = UInt32(offsets[row])
        }
        (storage + rowCount * 8).bindMemory(to: UInt8.self, capacity: rowCount)
            .update(from: rowFlags, count: rowCount)
        writePayload(storage + payloadStart)
    }

    deinit {
        storage.deallocate()
    }

    /// Bytes held by this chunk, not counting allocator rounding.
    var byteCount: Int { storageSize + 64 }

    /// The index of the live row with `key`, if this chunk holds one.
    func index(of key: Int) -> Int? {
        guard key >= firstKey, key <= lastKey else { return nil }
        let delta = UInt32(key - firstKey)
        var low = 0, high = rowCount - 1
        while low <= high {
            let middle = (low + high) / 2
            let candidate = keyDeltas[middle]
            if candidate == delta {
                return flags[middle] & Self.deadFlag == 0 ? middle : nil
            }
            if candidate < delta { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    func key(_ index: Int) -> Int { firstKey + Int(keyDeltas[index]) }

    func isWrapped(_ index: Int) -> Bool { flags[index] & Self.wrappedFlag != 0 }

    func kill(_ index: Int) {
        guard flags[index] & Self.deadFlag == 0 else { return }
        flags[index] |= Self.deadFlag
        liveCount -= 1
    }

    /// Marks every row with a key below `key` dead.
    func drop(below key: Int) {
        while dropCursor < rowCount && self.key(dropCursor) < key {
            kill(dropCursor)
            dropCursor += 1
        }
    }

    /// Decodes row `index` into a new line of `arena`.
    func makeLine(_ index: Int, arena: CellArena) -> BufferLine {
        let row = payload + Int(payloadOffsets[index])
        let header = row.loadUnaligned(as: ColdRowHeader.self)
        let cells = (row + ColdRowHeader.size).assumingMemoryBound(to: UInt64.self)
        return BufferLine(restoringWidth: Int(header.width), storedCount: Int(header.count),
                          tail: PackedCell(rawValue: header.tail),
                          isWrapped: isWrapped(index), bidiState: header.bidiState,
                          renderMode: header.lineRenderMode, arena: arena) { destination in
            HistoryRowCodec.decode(header.layout, from: cells, into: destination)
        }
    }
}

/// Every cold row of one buffer.
///
/// Chunks are kept in order of their first key. Keys of different chunks can
/// interleave (a row restored and moved out again lands in a newer chunk), so
/// lookups check every chunk whose key range covers the key; there are only
/// a few dozen chunks even for a long scrollback.
final class ColdHistory {
    private(set) var chunks: [HistoryChunk] = []

    /// Live rows held.
    var rowCount: Int { chunks.reduce(0) { $0 + $1.liveCount } }

    /// Bytes held, not counting allocator rounding.
    var byteCount: Int { chunks.reduce(0) { $0 + $1.byteCount } + chunks.capacity * 8 }

    var isEmpty: Bool { chunks.isEmpty }

    func add(_ chunk: HistoryChunk) {
        let position = chunks.firstIndex { $0.firstKey > chunk.firstKey } ?? chunks.count
        chunks.insert(chunk, at: position)
    }

    /// The chunk and index of the live row with `key`.
    func find(_ key: Int) -> (chunk: HistoryChunk, index: Int)? {
        for chunk in chunks {
            if chunk.firstKey > key { break }
            if let index = chunk.index(of: key) { return (chunk, index) }
        }
        return nil
    }

    /// Removes the live row with `key` and returns it rebuilt as a line.
    func take(_ key: Int, arena: CellArena) -> BufferLine? {
        guard let (chunk, index) = find(key) else { return nil }
        let line = chunk.makeLine(index, arena: arena)
        chunk.kill(index)
        if chunk.liveCount == 0 { remove(chunk) }
        return line
    }

    /// Rebuilds the live row with `key` without removing it.
    func peek(_ key: Int, arena: CellArena) -> BufferLine? {
        guard let (chunk, index) = find(key) else { return nil }
        return chunk.makeLine(index, arena: arena)
    }

    /// Whether the live row with `key` is soft-wrapped, without rebuilding it.
    func isWrapped(_ key: Int) -> Bool? {
        guard let (chunk, index) = find(key) else { return nil }
        return chunk.isWrapped(index)
    }

    /// Releases every row with a key below `key`: rows that were dropped off
    /// the top of the scrollback while they were cold.
    func drop(below key: Int) {
        var index = 0
        while index < chunks.count, chunks[index].firstKey < key {
            let chunk = chunks[index]
            chunk.drop(below: key)
            if chunk.liveCount == 0 {
                chunks.remove(at: index)
            } else {
                index += 1
            }
        }
    }

    func removeAll() {
        chunks.removeAll()
    }

    private func remove(_ chunk: HistoryChunk) {
        if let index = chunks.firstIndex(where: { $0 === chunk }) {
            chunks.remove(at: index)
        }
    }
}

/// Collects rows as they are moved out of the ring, then builds one
/// ``HistoryChunk`` at its exact size.
struct HistoryChunkBuilder {
    private var keys: [Int] = []
    private var offsets: [Int] = []
    private var flags: [UInt8] = []
    private var headers: [ColdRowHeader] = []
    private var cells: [UInt64] = []
    private var payloadSize = 0

    var isEmpty: Bool { keys.isEmpty }
    var count: Int { keys.count }

    /// Adds `line`, which is at `key`. Returns false, adding nothing, for a
    /// row the encoding cannot hold.
    mutating func add(_ line: BufferLine, key: Int) -> Bool {
        guard line.count <= Int(UInt16.max),
              keys.isEmpty || key - keys[0] <= Int(UInt32.max) else { return false }
        return line.withStoredCells { stored, tail in
            let layout = HistoryRowCodec.layout(of: stored)
            let size = ColdRowHeader.size + layout.wordCount * 8
            guard payloadSize + size <= Int(UInt32.max) else { return false }
            keys.append(key)
            offsets.append(payloadSize)
            flags.append(line.isWrapped ? HistoryChunk.wrappedFlag : 0)
            headers.append(ColdRowHeader(width: UInt16(line.count), count: UInt16(layout.count),
                                         runCount: UInt16(layout.runCount),
                                         contentWidth: UInt8(layout.contentWidth),
                                         renderMode: ColdRowHeader.renderModeCode(line.renderMode),
                                         bidiState: line.bidiState, tail: tail.rawValue))
            // Keep the raw cells until the chunk is built, so its storage can
            // be allocated once, at its exact size.
            cells.append(contentsOf: stored)
            payloadSize += size
            return true
        }
    }

    func build() -> HistoryChunk {
        HistoryChunk(keys: keys, payloadOffsets: offsets, flags: flags,
                     payloadSize: payloadSize) { payload in
            cells.withUnsafeBufferPointer { cells in
                var source = 0
                for (offset, header) in zip(offsets, headers) {
                    let row = payload + offset
                    row.storeBytes(of: header, as: ColdRowHeader.self)
                    let layout = header.layout
                    if layout.count > 0 {
                        HistoryRowCodec.encode(
                            UnsafeBufferPointer(rebasing: cells[source..<(source + layout.count)]),
                            layout: layout,
                            into: (row + ColdRowHeader.size).bindMemory(to: UInt64.self,
                                                                        capacity: layout.wordCount))
                    }
                    source += layout.count
                }
            }
        }
    }
}
