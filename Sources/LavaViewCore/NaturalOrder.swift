import Foundation

/// Filename ordering that reads runs of digits as numbers.
///
/// `IMG_2.jpg` before `IMG_10.jpg`. Byte order puts them the other way round,
/// which is wrong for the one thing this app does constantly — pressing Right
/// to walk a folder of photographs, whose names are almost always a prefix and
/// a counter.
///
/// Hand-written rather than `localizedStandardCompare`, for one reason worth
/// stating: the order a picture folder cycles in must not depend on the
/// machine's locale. Two people on the same directory, or the same person
/// after changing `LANG`, would otherwise disagree about what "next" is.
public enum NaturalOrder {
    /// True when `lhs` sorts before `rhs`.
    ///
    /// Digit runs compare by value, everything else by Unicode scalar with
    /// case folded — so `a10` sorts after `A9`, and a folder mixing `Photo`
    /// and `photo` does not split into two blocks. Ties on the folded form
    /// fall back to the raw scalars, so the order is still total and stable.
    public static func compare(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.unicodeScalars)
        let b = Array(rhs.unicodeScalars)
        var i = 0
        var j = 0

        while i < a.count, j < b.count {
            if isDigit(a[i]), isDigit(b[j]) {
                // Compare the whole runs, not one digit at a time: "0009" and
                // "9" are the same number, and leading zeros must not decide
                // it. Length after stripping them is the fast comparison;
                // digit-by-digit only when the runs are the same length.
                let (lhsRun, ni) = digitRun(a, from: i)
                let (rhsRun, nj) = digitRun(b, from: j)
                if lhsRun.count != rhsRun.count { return lhsRun.count < rhsRun.count }
                for k in 0..<lhsRun.count where lhsRun[k] != rhsRun[k] {
                    return lhsRun[k] < rhsRun[k]
                }
                i = ni
                j = nj
                continue
            }

            let ca = fold(a[i])
            let cb = fold(b[j])
            if ca != cb { return ca < cb }
            i += 1
            j += 1
        }

        if a.count != b.count { return a.count < b.count }
        // Same folded shape and same length — `Photo.png` vs `photo.png`.
        // Raw order breaks the tie so the sort is deterministic.
        return lhs < rhs
    }

    private static func isDigit(_ s: Unicode.Scalar) -> Bool {
        s.value >= 48 && s.value <= 57
    }

    /// The digits at `start`, leading zeros dropped, and the index after them.
    private static func digitRun(
        _ scalars: [Unicode.Scalar], from start: Int
    ) -> ([Unicode.Scalar], Int) {
        var end = start
        while end < scalars.count, isDigit(scalars[end]) { end += 1 }
        var begin = start
        while begin < end - 1, scalars[begin] == "0" { begin += 1 }
        return (Array(scalars[begin..<end]), end)
    }

    /// ASCII case folding only. Enough for filenames, and — unlike a full
    /// Unicode fold — it cannot depend on a locale.
    private static func fold(_ s: Unicode.Scalar) -> UInt32 {
        (s.value >= 65 && s.value <= 90) ? s.value + 32 : s.value
    }
}
