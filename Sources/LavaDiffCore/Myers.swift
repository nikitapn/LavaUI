/// Myers' O(ND) difference algorithm, in linear space.
///
/// The input is two arrays of small integers — lines (or tokens) interned so
/// that equal ones share a number — and the output is which elements of each
/// are *not* part of the longest common subsequence. Booleans per element,
/// rather than an edit script, because the next stage (`Slider`) moves change
/// boundaries around and a flag per line is the representation that makes that
/// a local edit.
///
/// Linear space is the divide-and-conquer form from the paper: find the middle
/// snake of the edit path, recurse on either side of it. The greedy form that
/// keeps every `V` array is simpler and needs O(D²) memory, which for a file
/// rewritten from end to end is hundreds of megabytes.
struct Myers {
    let a: [Int]
    let b: [Int]
    var changedA: [Bool]
    var changedB: [Bool]
    /// Past this many edits in one middle-snake search the region is declared
    /// different wholesale. Each search costs O((N+M)·D), and a diff of two
    /// unrelated 50k-line files would otherwise take minutes to say
    /// "everything changed" — which is the answer this gives at once.
    let costLimit: Int

    private var vf: [Int] = []
    private var vb: [Int] = []

    init(_ a: [Int], _ b: [Int], costLimit: Int = 4096) {
        self.a = a
        self.b = b
        self.changedA = Array(repeating: false, count: a.count)
        self.changedB = Array(repeating: false, count: b.count)
        self.costLimit = costLimit
    }

    mutating func run() {
        compare(0, a.count, 0, b.count)
    }

    private mutating func compare(_ aLo0: Int, _ aHi0: Int, _ bLo0: Int, _ bHi0: Int) {
        var aLo = aLo0, aHi = aHi0, bLo = bLo0, bHi = bHi0
        // Common prefix and suffix are free and, in source code, usually most
        // of the file.
        while aLo < aHi, bLo < bHi, a[aLo] == b[bLo] { aLo += 1; bLo += 1 }
        while aLo < aHi, bLo < bHi, a[aHi - 1] == b[bHi - 1] { aHi -= 1; bHi -= 1 }

        if aLo == aHi {
            for j in bLo..<bHi { changedB[j] = true }
            return
        }
        if bLo == bHi {
            for i in aLo..<aHi { changedA[i] = true }
            return
        }

        guard let snake = middleSnake(aLo, aHi, bLo, bHi) else {
            for i in aLo..<aHi { changedA[i] = true }
            for j in bLo..<bHi { changedB[j] = true }
            return
        }
        // Both halves are strictly smaller in edit distance once the ends are
        // trimmed, so this terminates. The guard is for the case that would
        // contradict that, so that a bug here is a coarse diff, not a hang.
        if snake.x == aLo, snake.y == bLo, snake.u == aHi, snake.v == bHi {
            return
        }
        if (snake.x, snake.y) == (aHi, bHi) || (snake.u, snake.v) == (aLo, bLo) {
            for i in aLo..<aHi { changedA[i] = true }
            for j in bLo..<bHi { changedB[j] = true }
            return
        }
        compare(aLo, snake.x, bLo, snake.y)
        compare(snake.u, aHi, snake.v, bHi)
    }

    /// The snake `(x, y) → (u, v)` that the optimal path crosses halfway, in
    /// absolute indices. Nil when finding it would exceed `costLimit`.
    private mutating func middleSnake(
        _ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int
    ) -> (x: Int, y: Int, u: Int, v: Int)? {
        let n = aHi - aLo
        let m = bHi - bLo
        let delta = n - m
        let odd = delta & 1 != 0
        let maxD = (n + m + 1) / 2
        let limit = min(maxD, costLimit)
        let offset = maxD + 1
        let size = 2 * maxD + 3
        if vf.count < size {
            vf = Array(repeating: 0, count: size)
            vb = Array(repeating: 0, count: size)
        }
        vf[offset + 1] = 0
        vb[offset + 1] = 0

        for d in 0...limit {
            // Forward: furthest x reached on each diagonal k = x - y.
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && vf[offset + k - 1] < vf[offset + k + 1]) {
                    x = vf[offset + k + 1]
                } else {
                    x = vf[offset + k - 1] + 1
                }
                var y = x - k
                let sx = x, sy = y
                while x < n, y < m, a[aLo + x] == b[bLo + y] { x += 1; y += 1 }
                vf[offset + k] = x
                // The backward search runs on the reversed sequences, where
                // this diagonal is `delta - k`.
                let kb = delta - k
                if odd, kb >= -(d - 1), kb <= d - 1, vf[offset + k] + vb[offset + kb] >= n {
                    return (aLo + sx, bLo + sy, aLo + x, bLo + y)
                }
            }
            // Backward, in reversed coordinates: x' = n - x, y' = m - y.
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && vb[offset + k - 1] < vb[offset + k + 1]) {
                    x = vb[offset + k + 1]
                } else {
                    x = vb[offset + k - 1] + 1
                }
                var y = x - k
                let sx = x, sy = y
                while x < n, y < m, a[aHi - 1 - x] == b[bHi - 1 - y] { x += 1; y += 1 }
                vb[offset + k] = x
                let kf = delta - k
                if !odd, kf >= -d, kf <= d, vb[offset + k] + vf[offset + kf] >= n {
                    return (aLo + n - x, bLo + m - y, aLo + n - sx, bLo + m - sy)
                }
            }
        }
        return nil
    }
}

/// Numbers each distinct element so that equal ones compare as equal integers.
struct Interner<Key: Hashable> {
    private var table: [Key: Int] = [:]

    mutating func id(_ key: Key) -> Int {
        if let id = table[key] { return id }
        let id = table.count
        table[key] = id
        return id
    }
}
