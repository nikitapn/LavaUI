import XCTest

@testable import LavaUI

/// A row keeps the structural key it was given until its id's occurrence
/// changes, and the key is only rebuilt then — so every pass must leave the
/// keys exactly as building them fresh would.
final class ForEachStructuralKeyTests: XCTestCase {
    /// An id with no description of its own: interpolating it goes through
    /// `Mirror`, which is what the reuse avoids.
    private struct RowID: Hashable { let raw: Int }

    private func keys(_ host: LayoutHost) throws -> [String] {
        var out: [String] = []
        func walk(_ node: any AnyViewNode) {
            if let key = node.structuralKey, key.hasPrefix("k:") { out.append(key) }
            node.childNodes.forEach(walk)
        }
        walk(try XCTUnwrap(host.rootNode))
        return out
    }

    private func set(_ host: LayoutHost, _ ids: [Int], textRow: Set<Int> = []) {
        let rows = ids.map { RowID(raw: $0) }
        host.setRoot(
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element) { _, row in
                    // A row that changes type is remounted, not reconciled.
                    if textRow.contains(row.raw) {
                        Text("row \(row.raw)")
                    } else {
                        Spacer().frame(width: .pt(4), height: .pt(4))
                    }
                }
            }
        )
    }

    private func expected(_ ids: [Int]) -> [String] {
        var seen: [Int: Int] = [:]
        return ids.map { id in
            let n = seen[id, default: 0]
            seen[id] = n + 1
            let base = "k:\(RowID(raw: id))"
            return n == 0 ? base : "\(base)#\(n)"
        }
    }

    func testKeysMatchAFreshBuildAcrossReuseDuplicatesAndRemounts() throws {
        let host = LayoutHost()
        let passes: [([Int], Set<Int>)] = [
            ([1, 2, 3], []),
            ([1, 2, 3], []),              // all reused
            ([3, 1, 2], []),              // reordered
            ([1, 1, 2], []),              // a duplicate appears
            ([1, 2, 1], []),              // the duplicate moves
            ([2, 1], []),                 // and goes
            ([2, 1, 4], [1]),             // a row remounts as another type
        ]
        for (ids, textRows) in passes {
            set(host, ids, textRow: textRows)
            XCTAssertEqual(try keys(host), expected(ids), "\(ids)")
        }
    }
}
