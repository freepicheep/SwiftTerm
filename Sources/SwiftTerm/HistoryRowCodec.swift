//
//  HistoryRowCodec.swift
//  SwiftTerm
//
//  Encodes the cells of one row into a compact, exact form for cold history.
//

/// The shape of one encoded row. ``HistoryRowCodec`` does not store it with
/// the words; the caller keeps it next to the row (see `ColdRow`).
struct HistoryRowLayout: Equatable {
    /// Cells encoded. The row's remaining cells are its tail blank.
    var count: Int
    /// Runs of cells that share everything but their content field. Zero when
    /// the cells are stored raw.
    var runCount: Int
    /// Bytes of content per cell: 1, 2 or 4, or 0 when stored raw.
    var contentWidth: Int

    /// 64-bit words the encoded row occupies.
    var wordCount: Int {
        contentWidth == 0
            ? count
            : runCount + (runCount + 1) / 2 + (count * contentWidth + 7) / 8
    }
}

/// Encodes a row's packed cells for cold history, and decodes them back.
///
/// A ``PackedCell`` is 64 bits: a 24-bit content field (a scalar, a grapheme
/// id, or a background color) and 40 bits of style, width, protection,
/// payload and semantic state. Across a row those 40 bits rarely change, so a
/// row is stored as:
///
/// - runs: the cell with its content cleared, one per run of cells that share
///   it, followed by the index where each run starts (32 bits each), then
/// - content: every cell's content field in 1, 2 or 4 bytes, the smallest
///   that holds the row's largest value.
///
/// A cell is its run's template ORed with its content shifted back in place,
/// so decoding is exact and the cell arena's identifiers are kept. A row where
/// runs would not save anything (CJK text alternates wide heads and spacer
/// tails, so almost every cell starts a run) is stored raw instead.
///
/// A plain 72-character line with one style is one template, one start and
/// 72 content bytes: 88 bytes, against 640 for the 80 cells it occupied.
///
/// Both directions process eight cells at a time with `SIMD8<UInt64>`. Rows of
/// shell output are long stretches of one style, so a block of eight whose
/// templates all match the current run is checked with one vector compare
/// and its content narrowed with one vector conversion; only blocks where a
/// run changes fall back to the per-cell loop.
enum HistoryRowCodec {
    private static let contentMask = PackedCell.contentMask
    private static let templateMask = ~PackedCell.contentMask
    private static let shift = PackedCell.contentShift

    // MARK: Layout

    /// Measures `cells` and picks their encoding.
    static func layout(of cells: UnsafeBufferPointer<UInt64>) -> HistoryRowLayout {
        let count = cells.count
        guard count > 0, let base = cells.baseAddress else {
            return HistoryRowLayout(count: 0, runCount: 0, contentWidth: 0)
        }
        var runCount = 1
        var template = base[0] & templateMask
        var maxContentVector = SIMD8<UInt64>(repeating: 0)
        let contentMaskVector = SIMD8<UInt64>(repeating: contentMask)
        let templateMaskVector = SIMD8<UInt64>(repeating: templateMask)
        var index = 0
        while index &+ 8 <= count {
            let block = load8(base + index)
            maxContentVector = pointwiseMax(maxContentVector, block & contentMaskVector)
            let templates = block & templateMaskVector
            if all(templates .== SIMD8(repeating: template)) {
                index &+= 8
                continue
            }
            for lane in 0..<8 {
                let next = templates[lane]
                if next != template {
                    runCount &+= 1
                    template = next
                }
            }
            index &+= 8
        }
        var maxTail: UInt64 = 0
        while index < count {
            let cell = base[index]
            maxTail = Swift.max(maxTail, cell & contentMask)
            let next = cell & templateMask
            if next != template {
                runCount &+= 1
                template = next
            }
            index &+= 1
        }
        let maxContent = Swift.max(maxContentVector.max(), maxTail) >> shift
        let contentWidth = maxContent <= 0xff ? 1 : (maxContent <= 0xffff ? 2 : 4)
        let encoded = HistoryRowLayout(count: count, runCount: runCount, contentWidth: contentWidth)
        if encoded.wordCount >= count {
            return HistoryRowLayout(count: count, runCount: 0, contentWidth: 0)
        }
        return encoded
    }

    // MARK: Encode

    /// Writes `cells` in `layout` (from ``layout(of:)``) to `words`, which
    /// must have room for `layout.wordCount` words.
    static func encode(_ cells: UnsafeBufferPointer<UInt64>, layout: HistoryRowLayout,
                       into words: UnsafeMutablePointer<UInt64>) {
        let count = layout.count
        guard count > 0, let base = cells.baseAddress else { return }
        precondition(cells.count == count)
        if layout.contentWidth == 0 {
            words.update(from: base, count: count)
            return
        }
        let runCount = layout.runCount
        let starts = UnsafeMutableRawPointer(words + runCount)
        let content = UnsafeMutableRawPointer(words + runCount + (runCount + 1) / 2)
        let templateMaskVector = SIMD8<UInt64>(repeating: templateMask)

        // Runs: the template of each, then where it starts.
        var run = 0
        var template = base[0] & templateMask
        words[0] = template
        starts.storeBytes(of: 0, as: UInt32.self)
        var index = 0
        while index < count {
            if index &+ 8 <= count,
               all((load8(base + index) & templateMaskVector) .== SIMD8(repeating: template)) {
                index &+= 8
                continue
            }
            let limit = min(index &+ 8, count)
            while index < limit {
                let next = base[index] & templateMask
                if next != template {
                    run &+= 1
                    template = next
                    words[run] = next
                    starts.storeBytes(of: UInt32(truncatingIfNeeded: index),
                                      toByteOffset: run &* 4, as: UInt32.self)
                }
                index &+= 1
            }
        }
        assert(run + 1 == runCount)

        // Content, narrowed eight cells at a time.
        let shiftVector = SIMD8<UInt64>(repeating: shift)
        index = 0
        switch layout.contentWidth {
        case 1:
            while index &+ 8 <= count {
                let narrow = SIMD8<UInt8>(truncatingIfNeeded: load8(base + index) &>> shiftVector)
                content.storeBytes(of: narrow, toByteOffset: index, as: SIMD8<UInt8>.self)
                index &+= 8
            }
            while index < count {
                content.storeBytes(of: UInt8(truncatingIfNeeded: base[index] >> shift),
                                   toByteOffset: index, as: UInt8.self)
                index &+= 1
            }
        case 2:
            while index &+ 8 <= count {
                let narrow = SIMD8<UInt16>(truncatingIfNeeded: load8(base + index) &>> shiftVector)
                content.storeBytes(of: narrow, toByteOffset: index &* 2, as: SIMD8<UInt16>.self)
                index &+= 8
            }
            while index < count {
                content.storeBytes(of: UInt16(truncatingIfNeeded: base[index] >> shift),
                                   toByteOffset: index &* 2, as: UInt16.self)
                index &+= 1
            }
        default:
            let contentMaskVector = SIMD8<UInt64>(repeating: contentMask)
            while index &+ 8 <= count {
                let narrow = SIMD8<UInt32>(truncatingIfNeeded:
                    (load8(base + index) & contentMaskVector) &>> shiftVector)
                content.storeBytes(of: narrow, toByteOffset: index &* 4, as: SIMD8<UInt32>.self)
                index &+= 8
            }
            while index < count {
                content.storeBytes(of: UInt32(truncatingIfNeeded: (base[index] & contentMask) >> shift),
                                   toByteOffset: index &* 4, as: UInt32.self)
                index &+= 1
            }
        }
    }

    // MARK: Decode

    /// Writes the `layout.count` cells encoded at `words` to `cells`.
    static func decode(_ layout: HistoryRowLayout, from words: UnsafePointer<UInt64>,
                       into cells: UnsafeMutablePointer<UInt64>) {
        let count = layout.count
        guard count > 0 else { return }
        if layout.contentWidth == 0 {
            cells.update(from: words, count: count)
            return
        }
        let runCount = layout.runCount
        let starts = UnsafeRawPointer(words + runCount)
        let content = UnsafeRawPointer(words + runCount + (runCount + 1) / 2)
        let shiftVector = SIMD8<UInt64>(repeating: shift)
        for run in 0..<runCount {
            let start = Int(starts.load(fromByteOffset: run &* 4, as: UInt32.self))
            let end = run &+ 1 < runCount
                ? Int(starts.load(fromByteOffset: (run &+ 1) &* 4, as: UInt32.self))
                : count
            let template = words[run]
            let templateVector = SIMD8<UInt64>(repeating: template)
            var index = start
            switch layout.contentWidth {
            case 1:
                while index &+ 8 <= end {
                    let narrow = content.loadUnaligned(fromByteOffset: index, as: SIMD8<UInt8>.self)
                    store8(templateVector | (SIMD8<UInt64>(truncatingIfNeeded: narrow) &<< shiftVector),
                           cells + index)
                    index &+= 8
                }
                while index < end {
                    cells[index] = template |
                        (UInt64(content.load(fromByteOffset: index, as: UInt8.self)) << shift)
                    index &+= 1
                }
            case 2:
                while index &+ 8 <= end {
                    let narrow = content.loadUnaligned(fromByteOffset: index &* 2, as: SIMD8<UInt16>.self)
                    store8(templateVector | (SIMD8<UInt64>(truncatingIfNeeded: narrow) &<< shiftVector),
                           cells + index)
                    index &+= 8
                }
                while index < end {
                    cells[index] = template |
                        (UInt64(content.loadUnaligned(fromByteOffset: index &* 2, as: UInt16.self)) << shift)
                    index &+= 1
                }
            default:
                while index &+ 8 <= end {
                    let narrow = content.loadUnaligned(fromByteOffset: index &* 4, as: SIMD8<UInt32>.self)
                    store8(templateVector | (SIMD8<UInt64>(truncatingIfNeeded: narrow) &<< shiftVector),
                           cells + index)
                    index &+= 8
                }
                while index < end {
                    cells[index] = template |
                        (UInt64(content.loadUnaligned(fromByteOffset: index &* 4, as: UInt32.self)) << shift)
                    index &+= 1
                }
            }
        }
    }

    // MARK: Vectors

    @inline(__always)
    private static func load8(_ pointer: UnsafePointer<UInt64>) -> SIMD8<UInt64> {
        UnsafeRawPointer(pointer).loadUnaligned(as: SIMD8<UInt64>.self)
    }

    @inline(__always)
    private static func store8(_ vector: SIMD8<UInt64>, _ pointer: UnsafeMutablePointer<UInt64>) {
        UnsafeMutableRawPointer(pointer).storeBytes(of: vector, as: SIMD8<UInt64>.self)
    }
}
