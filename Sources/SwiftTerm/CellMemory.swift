//
//  CellMemory.swift
//  SwiftTerm
//
//  The memory behind one terminal's rows of cells, in slabs this allocator maps
//  and unmaps itself.
//

#if !SWIFTTERM_EMBEDDED && (canImport(Darwin) || canImport(Glibc))
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Allocates the cell arrays of one terminal's rows from slabs it maps itself,
/// and gives a slab back to the system as soon as it is empty.
///
/// A row's cells are the bulk of its memory: 640 bytes for 80 columns, against
/// about 190 for its objects. From the system allocator, rows freed together
/// don't give their memory back. Freeing the history rows that
/// ``Terminal/compactHistory(_:)`` moves into cold storage freed about 8 MiB
/// per 10,000 lines, yet the process footprint barely moved: the allocator
/// spreads allocations of one size across its slabs (by design, as a
/// hardening measure), so the few rows still on screen kept nearly every slab
/// partly in use, and a partly used slab stays resident. Ghostty avoids the
/// same problem by owning its page memory; this does the same for cells.
///
/// Each block size (one per row width in use) has its own 256 KiB slabs,
/// aligned to their size so a block finds its slab by masking its address.
/// A slab's header sits at its start, followed by blocks handed out first from
/// a free list and then in order. New blocks come from the slab that most
/// recently had room, so rows allocated together stay together. When a slab's
/// last block is freed it is unmapped, except for one empty slab per size,
/// kept with its pages given back (`MADV_FREE_REUSABLE` / `MADV_DONTNEED`) so
/// that a row allocated and freed at a slab boundary doesn't map and unmap
/// repeatedly.
///
/// Rows wider than `largestBlock` allow, and zero-width rows, use the system
/// allocator. Blocks can be freed from any thread (a row's last reference can
/// be released anywhere), so every operation takes a lock; allocation happens
/// when rows are created, not per scroll, since the line ring reuses rows.
final class CellMemory: @unchecked Sendable {
    static let slabSize = 256 << 10
    /// Blocks up to this size come from slabs: rows up to 2,048 columns.
    static let largestBlock = 16 << 10
    /// Room for the header at the start of each slab. Blocks follow.
    private static let headerSize = 64

    private struct Header {
        /// Neighbours in the size's list of slabs with room.
        var next: UnsafeMutableRawPointer?
        var previous: UnsafeMutableRawPointer?
        var freeList: UnsafeMutableRawPointer?
        var blockSize: Int
        var live: Int
        /// Offset of the first block never handed out.
        var bump: Int
        var listed: Bool
    }

    private struct SizeClass {
        var blockSize: Int
        /// Slabs with room, the one to use first at the head.
        var available: UnsafeMutableRawPointer?
        /// An empty slab kept for reuse, with its pages given back.
        var spare: UnsafeMutableRawPointer?
    }

    private let lock = CellMemoryLock()
    private var classes: [SizeClass] = []
    /// Slabs currently mapped, the spares included.
    private(set) var mappedSlabCount = 0

    init() {}

    deinit {
        // Every block has been freed: a live row keeps its arena, and with it
        // this allocator, alive. Only the spares are still mapped.
        for sizeClass in classes {
            if let spare = sizeClass.spare { Self.unmap(spare) }
        }
    }

    /// Bytes mapped in slabs, spares included.
    var mappedBytes: Int { lock.withLock { mappedSlabCount * Self.slabSize } }

    // MARK: Allocation

    func allocate(count: Int) -> UnsafeMutableBufferPointer<PackedCell> {
        let size = count * MemoryLayout<PackedCell>.stride
        guard size > 0, size <= Self.largestBlock else {
            return .allocate(capacity: count)
        }
        let block = lock.withLock { allocateBlock(size: size) }
        return UnsafeMutableBufferPointer(
            start: block.bindMemory(to: PackedCell.self, capacity: count), count: count)
    }

    func deallocate(_ cells: UnsafeMutableBufferPointer<PackedCell>) {
        let size = cells.count * MemoryLayout<PackedCell>.stride
        guard size > 0, size <= Self.largestBlock, let base = cells.baseAddress else {
            cells.deallocate()
            return
        }
        lock.withLock { freeBlock(UnsafeMutableRawPointer(base), size: size) }
    }

    private func classIndex(size: Int) -> Int {
        if let index = classes.firstIndex(where: { $0.blockSize == size }) { return index }
        classes.append(SizeClass(blockSize: size))
        return classes.count - 1
    }

    private func allocateBlock(size: Int) -> UnsafeMutableRawPointer {
        let index = classIndex(size: size)
        if classes[index].available == nil {
            let slab = classes[index].spare.map { spare -> UnsafeMutableRawPointer in
                classes[index].spare = nil
                Self.reuse(spare)
                return spare
            } ?? mapSlab()
            header(slab).initialize(to: Header(blockSize: size, live: 0,
                                               bump: Self.headerSize, listed: false))
            link(slab, into: index)
        }
        let slab = classes[index].available!
        let slabHeader = header(slab)
        let block: UnsafeMutableRawPointer
        if let free = slabHeader.pointee.freeList {
            slabHeader.pointee.freeList = free.load(as: UnsafeMutableRawPointer?.self)
            block = free
        } else {
            block = slab + slabHeader.pointee.bump
            slabHeader.pointee.bump += size
        }
        slabHeader.pointee.live += 1
        if slabHeader.pointee.freeList == nil && slabHeader.pointee.bump + size > Self.slabSize {
            unlink(slab, from: index)
        }
        return block
    }

    private func freeBlock(_ block: UnsafeMutableRawPointer, size: Int) {
        let slab = Self.slab(of: block)
        let slabHeader = header(slab)
        precondition(slabHeader.pointee.blockSize == size, "CellMemory: freeing a block of the wrong size")
        block.storeBytes(of: slabHeader.pointee.freeList, as: UnsafeMutableRawPointer?.self)
        slabHeader.pointee.freeList = block
        slabHeader.pointee.live -= 1
        let index = classIndex(size: size)
        if slabHeader.pointee.live == 0 {
            if slabHeader.pointee.listed { unlink(slab, from: index) }
            if classes[index].spare == nil {
                Self.release(slab)
                classes[index].spare = slab
            } else {
                Self.unmap(slab)
                mappedSlabCount -= 1
            }
        } else if !slabHeader.pointee.listed {
            link(slab, into: index)
        }
    }

    // MARK: Slab lists

    private func header(_ slab: UnsafeMutableRawPointer) -> UnsafeMutablePointer<Header> {
        slab.assumingMemoryBound(to: Header.self)
    }

    private static func slab(of block: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: block) & ~UInt(slabSize - 1))!
    }

    private func link(_ slab: UnsafeMutableRawPointer, into index: Int) {
        let slabHeader = header(slab)
        slabHeader.pointee.previous = nil
        slabHeader.pointee.next = classes[index].available
        if let head = classes[index].available { header(head).pointee.previous = slab }
        classes[index].available = slab
        slabHeader.pointee.listed = true
    }

    private func unlink(_ slab: UnsafeMutableRawPointer, from index: Int) {
        let slabHeader = header(slab)
        if let previous = slabHeader.pointee.previous {
            header(previous).pointee.next = slabHeader.pointee.next
        } else {
            classes[index].available = slabHeader.pointee.next
        }
        if let next = slabHeader.pointee.next { header(next).pointee.previous = slabHeader.pointee.previous }
        slabHeader.pointee.next = nil
        slabHeader.pointee.previous = nil
        slabHeader.pointee.listed = false
    }

    // MARK: Mapping

    /// Maps a slab aligned to its size: maps twice the size and unmaps the
    /// excess on either side.
    private func mapSlab() -> UnsafeMutableRawPointer {
        let size = Self.slabSize
        guard let raw = mmap(nil, size * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              raw != MAP_FAILED else {
            preconditionFailure("CellMemory: cannot map a slab")
        }
        let address = UInt(bitPattern: raw)
        let aligned = (address + UInt(size - 1)) & ~UInt(size - 1)
        let lead = Int(aligned - address)
        if lead > 0 { munmap(raw, lead) }
        let trail = size - lead
        if trail > 0 { munmap(UnsafeMutableRawPointer(bitPattern: aligned + UInt(size))!, trail) }
        mappedSlabCount += 1
        return UnsafeMutableRawPointer(bitPattern: aligned)!
    }

    private static func unmap(_ slab: UnsafeMutableRawPointer) {
        munmap(slab, slabSize)
    }

    /// Gives an empty slab's pages back to the system, keeping the mapping.
    private static func release(_ slab: UnsafeMutableRawPointer) {
        #if canImport(Darwin)
        _ = madvise(slab, slabSize, MADV_FREE_REUSABLE)
        #else
        _ = madvise(slab, slabSize, MADV_DONTNEED)
        #endif
    }

    /// Takes back a slab given up with `release`.
    private static func reuse(_ slab: UnsafeMutableRawPointer) {
        #if canImport(Darwin)
        _ = madvise(slab, slabSize, MADV_FREE_REUSE)
        #endif
    }
}

/// The smallest lock the platform has: `os_unfair_lock` or a pthread mutex.
private final class CellMemoryLock: @unchecked Sendable {
    #if canImport(Darwin)
    private let lock: UnsafeMutablePointer<os_unfair_lock_s>

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    @inline(__always)
    func withLock<Result>(_ body: () -> Result) -> Result {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }
    #else
    private let lock: UnsafeMutablePointer<pthread_mutex_t>

    init() {
        lock = .allocate(capacity: 1)
        pthread_mutex_init(lock, nil)
    }

    deinit {
        pthread_mutex_destroy(lock)
        lock.deallocate()
    }

    @inline(__always)
    func withLock<Result>(_ body: () -> Result) -> Result {
        pthread_mutex_lock(lock)
        defer { pthread_mutex_unlock(lock) }
        return body()
    }
    #endif
}
#endif
