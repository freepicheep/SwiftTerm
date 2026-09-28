//
//  CircularList.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/25/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

#if !SWIFTTERM_EMBEDDED
import Foundation
#endif

enum ArgumentError : Error {
    case invalidArgument(String)
}

final class CircularList<T> {
    private var array: [T?]
    private var startIndex: Int
    var count: Int {
        get {
            return _count
        }
        set {
            precondition(newValue <= maxLength)

            if newValue > array.count {
                let start = array.count
                for _ in start..<newValue {
                    array.append (nil)
                }
            }
            _count = newValue
        }
    }

    private var _count: Int
    var maxLength: Int {
        didSet {
            if maxLength != oldValue {
                let empty : T? = nil
                var newArray = Array(repeating: empty, count:Int(maxLength))
                let top = min (maxLength, array.count)
                for i in 0..<top {
                    newArray [i] = array [getCyclicIndex(i)]
                }
                startIndex = 0
                array = newArray
                return
            }
        }
    }

    ///
    /// This method is called to fill a slot that might be empty on demand, gets a -1 for a row that
    /// does not exist, or the index requested otherwise
    //
    var makeEmpty: ((_ idx: Int) -> T)? = nil

    public init (maxLength: Int)
    {
        array = Array.init(repeating: nil, count: Int(maxLength))
        self.maxLength = maxLength
        self._count = 0
        self.startIndex = 0
    }

    private func getCyclicIndex(_ index: Int) -> Int {
        return Int(startIndex + index) % (array.count)
    }

    func debugGetCyclicIndex(_ index: Int) -> Int {
        getCyclicIndex(index)
    }

    subscript (index: Int) -> T {
        get {
            let idx = getCyclicIndex(index)
            if let p = array [idx] {
                return p
            } else {
                guard let makeEmpty = makeEmpty else {
                    preconditionFailure("makeEmpty closure must be configured for CircularList when slot is nil")
                }
                let new = makeEmpty (idx)
                array [idx] = new
                return new
            }
        }
        set (newValue){
            array [getCyclicIndex(index)] = newValue
      }
    }

    func push (_ value: T)
    {
        array [getCyclicIndex(count)] = value
        if count == array.count {
            startIndex = startIndex + 1
            if startIndex == array.count {
                startIndex = 0
            }
        } else {
            count = count + 1
        }
    }

    func recycle ()
    {
        precondition(count == maxLength, "can only recycle when the buffer is full")
        guard let makeEmpty = makeEmpty else {
            preconditionFailure("makeEmpty closure must be configured for CircularList")
        }
        let index = getCyclicIndex(count)
        startIndex += 1
        startIndex = startIndex % maxLength
        array [index] = makeEmpty (-1)
    }

    @discardableResult
    func pop () -> T {
        let v = array [getCyclicIndex(count-1)]!
        count = count - 1
        return v
    }

    func splice (start: Int, deleteCount: Int, items: [T], change: (Int) -> Void)
    {
        if deleteCount > 0 {
            var i = start
            let limit = count-deleteCount
            while i < limit {
                array [getCyclicIndex(i)] = array [getCyclicIndex(i+deleteCount)]
                change(i)
                i += 1
            }
            count = count - deleteCount
        }
        // add items
        var i = count-1
        let ic = items.count
        while i >= start {
#if DEBUG
            // print("Moving line \(i) to \(i + ic): \(array[getCyclicIndex(i)].debugDescription)")
#endif
            array [getCyclicIndex(i + ic)] = array [getCyclicIndex(i)]
            change(i + ic)
            i -= 1
        }
        for i in 0..<ic {
            change(start + i)
            array [getCyclicIndex(start + i)] = items [i]
        }

        // Adjust length as needed
        if Int(count) + ic > array.count {
            let countToTrim = count + items.count - array.count
            startIndex = startIndex + countToTrim
            count = array.count
        } else {
            count = count + items.count
        }
     }

    func trimStart (count: Int)
    {
        let c = count > self.count ? self.count : count
        startIndex = startIndex + c
        self.count -= count
    }

    func shiftElements (start: Int, count: Int, offset: Int) -> Bool
    {
        func dumpState (_ msg: String) -> Bool {
            print ("Assertion at start=\(start) count=\(count) offset=\(offset): \(msg)")
            return false
        }

        if count < 0 {
            return dumpState ("count < 0")
        }
        if start < 0 {
            return dumpState ("start < 0")
        }
        if start >= self.count {
            return dumpState ("start >= self.count")
        }
        if start+offset <= 0 {
            return dumpState ("start+offset <= 0")
        }
//        precondition (count > 0)
//        precondition (start >= 0)
//        precondition (start < self.count)
//        precondition (start+offset > 0)
        if offset > 0 {
            for i in (0..<count).reversed() {
                self [start + i + offset] = self [start + i]
            }
            let expandListBy = start + count + offset - self.count
            if expandListBy > 0 {
                self._count += expandListBy
                while self._count > maxLength {
                    self._count -= 1
                    startIndex += 1
                    // trimmed callback invoke
                }
            }
        } else {
            for i in 0..<count {
                self [start + i + offset] = self [start + i]
            }
        }
        return true
    }

    var isFull: Bool {
        get {
            return count == maxLength
        }
    }
}

internal final class CircularBufferLineList {
#if DEBUG
    private var array: [BufferLine?]
#else
    @exclusivity(unchecked) private var array: [BufferLine?]
#endif
    private var startIndex: Int
    var count: Int {
        get {
            return _count
        }
        set {
            precondition(newValue <= maxLength)

            if newValue > array.count {
                grow(toHold: newValue)
            }
            _count = newValue
        }
    }

    public var isEmpty: Bool { count == 0 }
    public func getArray() -> [BufferLine?] {
        array
    }

    public func getStartIndex() -> Int {
        startIndex
    }

    private var _count: Int
    var maxLength: Int {
        didSet {
            if maxLength != oldValue {
                // Keep the slots in use; a larger limit is reached by growing
                // later, as lines arrive.
                let capacity = min(maxLength, array.count)
                let empty : BufferLine? = nil
                var newArray = Array(repeating: empty, count: capacity)
                for i in 0..<capacity {
                    newArray [i] = array [getCyclicIndex(i)]
                }
                startIndex = 0
                array = newArray
                return
            }
        }
    }

    /// Slots allocated when the list is created or reset.
    ///
    /// The slot array used to be allocated at `maxLength` up front: 8 bytes for
    /// every line of scrollback a terminal might ever hold, 40 KiB for a
    /// 5,000-line history before a single line was written. It now starts at
    /// this size and doubles as lines arrive, up to `maxLength`. The ring only
    /// wraps (reusing its oldest slot) once it has reached `maxLength`, so the
    /// order of lines never depends on the current capacity.
    static let initialCapacity = 64

    /// Slots currently allocated. At most `maxLength`.
    var capacity: Int { array.count }

    /// Makes room for at least `needed` lines (capped at `maxLength`), keeping
    /// every slot's contents in logical order from slot zero.
    @inline(never)
    private func grow(toHold needed: Int) {
        let newCapacity = min(maxLength, max(needed, array.count * 2, Self.initialCapacity))
        guard newCapacity > array.count else { return }
        let empty : BufferLine? = nil
        var newArray = Array(repeating: empty, count: newCapacity)
        for i in 0..<array.count {
            newArray [i] = array [getCyclicIndex(i)]
        }
        startIndex = 0
        array = newArray
    }

    /// The buffer this list belongs to.
    ///
    /// This used to be four separate `[weak self]` / `[unowned self]` closures
    /// (`makeEmpty`, `onLineRecycled`, `onLinePushed`, `onLineAttached`), every
    /// one of which called straight back into the owning ``Buffer``. The `weak`
    /// captures among them put `Buffer` on the runtime's side-table refcount
    /// path for good, which costs about 9x on every retain and release of the
    /// buffer — and `onLineRecycled` fired on each scrolled line, paying a weak
    /// load on top. A plain back-pointer removes the side table, the weak load,
    /// and the closure indirection at once.
    ///
    /// `unowned(unsafe)` is sound here because the list is a private stored
    /// property of the buffer: it cannot outlive its owner, and no path hands a
    /// list to anyone else. See `Docs/io-cpu-profile.md` §3.1.
#if SWIFTTERM_EMBEDDED
    var owner: Buffer? = nil
#else
    unowned(unsafe) var owner: Buffer! = nil
#endif

    // Embedded needs a breakable optional owner to release its object graph.
    // Normal builds use the non-optional `unowned(unsafe)` owner above. Keep
    // the callbacks below direct in that configuration: they run for every
    // attached or recycled row, and using `owner?.` for both builds caused a
    // measurable scrolling regression.

    /// True only for a buffer's live line list.
    ///
    /// Reflow builds scratch lists to stage a rearrangement. Those need `owner`
    /// so an empty slot can still be filled, but they must not stamp line
    /// ownership or move the buffer's image counter — the lines they hold are
    /// already counted, and staging them again would double-count. Back when
    /// these were four independent optional closures, scratch lists got that for
    /// free by installing only `makeEmpty` and leaving the notification hooks
    /// nil. This flag preserves that split now that one back-pointer serves all
    /// four roles.
    var isLive: Bool = false

    public init (maxLength: Int)
    {
        array = Array.init(repeating: nil, count: min(maxLength, Self.initialCapacity))
        self.maxLength = maxLength
        self._count = 0
        self.startIndex = 0
    }

    /// The private version exists to allow the Swift optimizer to avoid calls to
    /// `swift_beginAccess`
    private func getCyclicIndex(_ index: Int) -> Int {
        return Int(startIndex &+ index) % (array.count)
    }

    /// Public version of the same method
    func debugGetCyclicIndex(_ index: Int) -> Int {
        return getCyclicIndex(index)
    }

    subscript (index: Int) -> BufferLine {
        _read {
            let idx = getCyclicIndex(index)
            if array[idx] == nil {
                fillEmptySlot(idx, index: index)
            }
            yield array[idx]!
        }
        set (newValue){
            array [getCyclicIndex(index)] = newValue
#if SWIFTTERM_EMBEDDED
            if isLive { owner?.lineAttached(newValue) }
#else
            if isLive { owner.lineAttached(newValue) }
#endif
      }
    }

    /// Fills an empty slot: either never filled, or holding a row that moved
    /// into cold history, which the owner restores. Out of line, so the
    /// subscript inlined into every hot path stays as small as before.
    @inline(never)
    private func fillEmptySlot(_ idx: Int, index: Int) {
#if SWIFTTERM_EMBEDDED
        array[idx] = isLive ? owner!.lineForEmptySlot(at: index) : owner!.makeEmptyLine(idx)
#else
        array[idx] = isLive ? owner.lineForEmptySlot(at: index) : owner.makeEmptyLine(idx)
#endif
    }

    /// The oldest row was in cold history when the full ring recycled its
    /// slot. The row is dropped now, and the slot needs a line object again
    /// for the new bottom row.
    @inline(never)
    private func refillDroppedColdSlot(_ idx: Int) {
#if SWIFTTERM_EMBEDDED
        array[idx] = owner!.lineForDroppedColdRow()
#else
        array[idx] = owner.lineForDroppedColdRow()
#endif
    }

    /// The line in slot `index`, or nil when the slot is empty (for example
    /// because its row is in cold history). Unlike the subscript, this never
    /// fills the slot.
    func peek(_ index: Int) -> BufferLine? {
        array[getCyclicIndex(index)]
    }

    /// Empties slot `index` and returns its line, if the ring held the only
    /// reference to it. A line referenced elsewhere is left in place, since a
    /// later change through that reference must stay visible in the buffer.
    func takeUniquelyReferenced(_ index: Int) -> BufferLine? {
        let idx = getCyclicIndex(index)
        guard var line = array[idx] else { return nil }
        array[idx] = nil
        if isKnownUniquelyReferenced(&line) {
            return line
        }
        array[idx] = line
        return nil
    }

    func push (_ value: BufferLine)
    {
#if SWIFTTERM_EMBEDDED
        if isLive { owner?.lineAttached(value) }
#else
        if isLive { owner.lineAttached(value) }
#endif
        if _count == array.count && array.count < maxLength {
            grow(toHold: _count + 1)
        }
        array [getCyclicIndex(count)] = value
        if count == array.count {
            startIndex = startIndex + 1
            if startIndex == array.count {
                startIndex = 0
            }
            droppedCount &+= 1
        } else {
            count = count + 1
        }
#if SWIFTTERM_EMBEDDED
        if isLive { owner?.lineDidPush(hasImages: value.images != nil) }
#else
        if isLive { owner.lineDidPush(hasImages: value.images != nil) }
#endif
    }

    /// Recycles a row with state that already belongs to the owner's arena.
    func recycle(clearCell: PackedCell, isWrapped: Bool,
                 bidiState: BidiPresentationState)
    {
        assert(startIndex < array.count)
        precondition(count == maxLength, "can only recycle when the buffer is full")
        // A full ring makes getCyclicIndex(count) equal to startIndex.
        let index = startIndex
        let next = startIndex &+ 1
        startIndex = next == maxLength ? 0 : next
        droppedCount &+= 1
        if array[index] == nil {
            refillDroppedColdSlot(index)
        }
        // The array owns the line until this function finishes using it.
#if SWIFTTERM_EMBEDDED
        let line = array[index]!
#else
        unowned(unsafe) let line = array[index]!
#endif
        // The line object is being destroyed for reuse. Clear its cells and
        // metadata with one generation change.
        let hadImages = line.recycle(with: clearCell, isWrapped: isWrapped,
                                     bidiState: bidiState)
#if SWIFTTERM_EMBEDDED
        if isLive { owner?.lineWillRecycle(hadImages: hadImages) }
#else
        if isLive { owner.lineWillRecycle(hadImages: hadImages) }
#endif
    }

    @discardableResult
    func pop () -> BufferLine {
        let v = array [getCyclicIndex(count-1)]!
        count = count - 1
        return v
    }

    func splice (start: Int, deleteCount: Int, items: [BufferLine], change: (Int) -> Void)
    {
        if deleteCount > 0 {
            var i = start
            let limit = count-deleteCount
            while i < limit {
                array [getCyclicIndex(i)] = array [getCyclicIndex(i+deleteCount)]
                change(i)
                i += 1
            }
            count = count - deleteCount
        }
        if count + items.count > array.count {
            grow(toHold: count + items.count)
        }
        // add items
        var i = count-1
        let ic = items.count
        while i >= start {
#if DEBUG
            // print("Moving line \(i) to \(i + ic): \(array[getCyclicIndex(i)].debugDescription)")
#endif
            array [getCyclicIndex(i + ic)] = array [getCyclicIndex(i)]
            change(i + ic)
            i -= 1
        }
        for i in 0..<ic {
            change(start + i)
#if SWIFTTERM_EMBEDDED
            if isLive { owner?.lineAttached(items [i]) }
#else
            if isLive { owner.lineAttached(items [i]) }
#endif
            array [getCyclicIndex(start + i)] = items [i]
        }

        // Adjust length as needed
        if Int(count) + ic > array.count {
            let countToTrim = count + items.count - array.count
            startIndex = startIndex + countToTrim
            if !array.isEmpty {
                startIndex %= array.count
            }
            droppedCount &+= countToTrim
            count = array.count
        } else {
            count = count + items.count
        }
     }

    func trimStart (count: Int)
    {
        let c = count > self.count ? self.count : count
        startIndex = startIndex + c
        if !array.isEmpty {
            startIndex %= array.count
        }
        droppedCount &+= c
        self.count -= count
    }

    func shiftElements (start: Int, count: Int, offset: Int) -> Bool
    {
        func dumpState (_ msg: String) -> Bool {
            print ("Assertion at start=\(start) count=\(count) offset=\(offset): \(msg)")
            return false
        }

        if count < 0 {
            return dumpState ("count < 0")
        }
        if start < 0 {
            return dumpState ("start < 0")
        }
        if start >= self.count {
            return dumpState ("start >= self.count")
        }
        if start+offset <= 0 {
            return dumpState ("start+offset <= 0")
        }
        if offset > 0 {
            if start + count + offset > array.count {
                grow(toHold: start + count + offset)
            }
            for i in (0..<count).reversed() {
                array[getCyclicIndex(start + i + offset)] = array[getCyclicIndex(start + i)]
            }
            let expandListBy = start + count + offset - self.count
            if expandListBy > 0 {
                self._count += expandListBy
                while self._count > maxLength {
                    self._count -= 1
                    startIndex += 1
                    if !array.isEmpty {
                        startIndex %= array.count
                    }
                    droppedCount &+= 1
                }
            }
        } else {
            for i in 0..<count {
                array[getCyclicIndex(start + i + offset)] = array[getCyclicIndex(start + i)]
            }
        }
        return true
    }

    /// Moves a full-width region up by one row and reuses its former top row.
    /// The logical count and the circular start index do not change.
    func shiftUpAndRecycle(top: Int, bottom: Int, clearCell: PackedCell,
                           isWrapped: Bool,
                           bidiState: BidiPresentationState) -> Bool
    {
        func dumpState (_ message: String) -> Bool {
            print("Assertion at top=\(top) bottom=\(bottom): \(message)")
            return false
        }

        if top < 0 {
            return dumpState("top < 0")
        }
        if bottom < top {
            return dumpState("bottom < top")
        }
        if bottom >= count {
            return dumpState("bottom >= count")
        }

        // Keep this reference alive while its array slot is overwritten.
        let recycledLine = self[top]
        let hadImages = recycledLine.images != nil
        let firstPhysicalIndex = startIndex
        let capacity = array.count

        // The local reference must stay alive until its array ownership moves
        // to the last slot.
        withExtendedLifetime(recycledLine) {
            array.withUnsafeMutableBufferPointer { lines in
                lines.withMemoryRebound(to: UnsafeMutableRawPointer?.self) { slots in
                    // Each line keeps one array reference. A raw store moves that
                    // reference to the preceding slot without ARC work.
                    var destination = (firstPhysicalIndex &+ top) % capacity
                    if top < bottom {
                        let moveCount = bottom - top
                        if destination + moveCount < capacity {
                            // The existing raw-pointer binding transfers the
                            // array's strong references without ARC operations.
                            // This range is contiguous and overlaps by one slot,
                            // so memmove preserves that ownership transfer.
#if SWIFTTERM_EMBEDDED
                            for offset in 0..<moveCount {
                                slots[destination + offset] = slots[destination + offset + 1]
                            }
#else
                            let byteCount = moveCount *
                                MemoryLayout<UnsafeMutableRawPointer?>.stride
                            memmove(slots.baseAddress!.advanced(by: destination),
                                    slots.baseAddress!.advanced(by: destination + 1),
                                    byteCount)
#endif
                            destination += moveCount
                        } else {
                            // Keep the element loop when the circular range wraps.
                            for _ in top..<bottom {
                                var source = destination + 1
                                if source == capacity {
                                    source = 0
                                }
                                slots[destination] = slots[source]
                                destination = source
                            }
                        }
                    }
                    // The former last line is already in the preceding slot. Do
                    // not release it when recycledLine moves into this slot.
                    slots[destination] = Unmanaged.passUnretained(recycledLine).toOpaque()
                }
            }
        }

        recycledLine.recycle(with: clearCell, isWrapped: isWrapped,
                             bidiState: bidiState)
        if isLive {
#if SWIFTTERM_EMBEDDED
            owner?.lineWillRecycle(hadImages: hadImages)
#else
            owner.lineWillRecycle(hadImages: hadImages)
#endif
        }
        return true
    }

    /// Empties the ring in place and gives it `newMaxLength` slots.
    ///
    /// `Buffer.clear` uses this instead of replacing its list object. That
    /// keeps `Buffer._lines` a `let`, which lets the optimizer borrow the list
    /// at +0 on every ring access instead of retaining it around each load in
    /// case the property is reassigned underneath the access.
    ///
    /// Like `push`, `recycle`, and `shiftUpAndRecycle`, a live list keeps the
    /// owner's image accounting correct itself: every dropped line that
    /// carried images is reported before it goes.
    func reset(maxLength newMaxLength: Int) {
        if isLive {
            for line in array where line?.images != nil {
#if SWIFTTERM_EMBEDDED
                owner?.lineWillRecycle(hadImages: true)
#else
                owner.lineWillRecycle(hadImages: true)
#endif
            }
        }
        _count = 0
        startIndex = 0
        droppedCount = 0
        if maxLength != newMaxLength {
            maxLength = newMaxLength
        }
        // Give back the slots a long history grew; an unchanged small ring
        // is cleared in place without allocating.
        let initial = min(maxLength, Self.initialCapacity)
        if array.count > initial {
            array = Array(repeating: nil, count: initial)
        } else {
            for index in array.indices {
                array[index] = nil
            }
        }
    }

    var isFull: Bool {
        get {
            return count == maxLength
        }
    }

    // Declared last so that it does not move the offsets of the hot fields.
    /// Lines dropped off the start of the ring since it was created or reset:
    /// the oldest line recycled or overwritten by a full ring, or trimmed.
    ///
    /// `droppedCount + index` names a line independently of how many lines
    /// have been dropped since. Cold history uses it to find the row that
    /// belongs in an empty slot. Every operation that moves lines toward the
    /// start does so only by dropping them here; operations that shift lines
    /// in the middle of the ring work on screen rows, below any history.
    private(set) var droppedCount = 0
}
