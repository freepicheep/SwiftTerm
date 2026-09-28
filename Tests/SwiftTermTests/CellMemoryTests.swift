//
//  CellMemoryTests.swift
//
//  CellMemory hands out the cell arrays of a terminal's rows from slabs it maps
//  itself, and unmaps a slab as soon as it is empty.
//

#if !SWIFTTERM_EMBEDDED && (canImport(Darwin) || canImport(Glibc))
import Foundation
import Testing

@testable import SwiftTerm

@Suite final class CellMemoryTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    private func fill(_ cells: UnsafeMutableBufferPointer<PackedCell>, _ tag: UInt64) {
        for index in cells.indices {
            cells[index] = PackedCell(rawValue: tag << 32 | UInt64(index))
        }
    }

    private func check(_ cells: UnsafeMutableBufferPointer<PackedCell>, _ tag: UInt64) -> Bool {
        cells.indices.allSatisfy { cells[$0].rawValue == tag << 32 | UInt64($0) }
    }

    @Test func blocksAreDistinctAndKeepTheirContents() {
        let memory = CellMemory()
        var blocks: [UnsafeMutableBufferPointer<PackedCell>] = []
        for tag in 0..<2_000 {
            let block = memory.allocate(count: 80)
            fill(block, UInt64(tag))
            blocks.append(block)
        }
        #expect(blocks.enumerated().allSatisfy { check($0.element, UInt64($0.offset)) })
        // 2,000 rows of 640 bytes need five 256 KiB slabs.
        #expect(memory.mappedBytes == 5 * CellMemory.slabSize)
        for block in blocks { memory.deallocate(block) }
    }

    @Test func emptySlabsAreGivenBack() {
        let memory = CellMemory()
        var blocks = (0..<4_000).map { _ in memory.allocate(count: 80) }
        let full = memory.mappedBytes
        #expect(full >= 10 * CellMemory.slabSize)
        // Free all but the last few, as compacting history does.
        let survivors = Array(blocks.suffix(24))
        for block in blocks.dropLast(24) { memory.deallocate(block) }
        blocks = survivors
        // The survivors' slab, and one empty spare, stay mapped.
        #expect(memory.mappedBytes <= 2 * CellMemory.slabSize)
        // Freed space is reused before new slabs are mapped.
        let again = (0..<300).map { _ in memory.allocate(count: 80) }
        #expect(memory.mappedBytes <= 2 * CellMemory.slabSize)
        for block in again + blocks { memory.deallocate(block) }
        #expect(memory.mappedBytes == CellMemory.slabSize)
    }

    @Test func sizesHaveTheirOwnSlabs() {
        let memory = CellMemory()
        var blocks: [(UnsafeMutableBufferPointer<PackedCell>, UInt64)] = []
        for round in 0..<600 {
            let count = [80, 132, 40, 2_048, 1][round % 5]
            let block = memory.allocate(count: count)
            fill(block, UInt64(round))
            blocks.append((block, UInt64(round)))
            if round % 7 == 3 {
                let (freed, _) = blocks.remove(at: blocks.count / 2)
                memory.deallocate(freed)
            }
        }
        #expect(blocks.allSatisfy { check($0.0, $0.1) })
        for (block, _) in blocks { memory.deallocate(block) }
        // One empty spare per size.
        #expect(memory.mappedBytes <= 5 * CellMemory.slabSize)
    }

    @Test func oversizedAndEmptyRowsUseTheSystemAllocator() {
        let memory = CellMemory()
        let wide = memory.allocate(count: CellMemory.largestBlock / 8 + 1)
        let empty = memory.allocate(count: 0)
        #expect(memory.mappedBytes == 0)
        fill(wide, 7)
        #expect(check(wide, 7))
        memory.deallocate(wide)
        memory.deallocate(empty)
    }

    @Test func blocksCanBeFreedFromAnyThread() {
        let memory = CellMemory()
        let blocks = (0..<8_000).map { _ in memory.allocate(count: 80) }
        let addresses = blocks.map { UInt(bitPattern: $0.baseAddress!) }
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in stride(from: worker, to: addresses.count, by: 8) {
                let base = UnsafeMutablePointer<PackedCell>(bitPattern: addresses[index])!
                memory.deallocate(UnsafeMutableBufferPointer(start: base, count: 80))
                // Interleave allocations with the frees of other threads.
                if index % 3 == 0 {
                    memory.deallocate(memory.allocate(count: 80))
                }
            }
        }
        #expect(memory.mappedBytes == CellMemory.slabSize)
    }

    @Test func compactingHistoryGivesItsSlabsBack() {
        let terminal = Terminal(delegate: self,
                                options: TerminalOptions(cols: 80, rows: 24, scrollback: 10_000))
        var text = ""
        for i in 0..<10_000 { text += "line \(i) " + String(repeating: "x", count: i % 70) + "\r\n" }
        terminal.feed(text: text)
        let memory = terminal.buffer.cellArena.cellMemory!
        let filled = memory.mappedBytes
        #expect(filled >= 10_000 * 640)
        terminal.compactHistory(.full)
        // Only the screen's rows are left: a slab or two.
        #expect(memory.mappedBytes <= 3 * CellMemory.slabSize)
        // Reading history back allocates again, and compacting frees it again.
        for row in 0..<10_000 { _ = terminal.getScrollInvariantLine(row: row) }
        #expect(memory.mappedBytes >= 10_000 * 640)
        terminal.compactHistory(.full)
        #expect(memory.mappedBytes <= 3 * CellMemory.slabSize)
    }
}
#endif
