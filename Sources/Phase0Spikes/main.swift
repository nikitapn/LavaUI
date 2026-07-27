import Foundation

/// Phase 0 prep spikes from docs/declarative-ui-plan.md.
/// Throwaway: proves parameter packs, Yoga measure from Swift, Font interop.
@main
struct Phase0Spikes {
    static func main() {
        var failed = 0
        if !Spike0a.run() { failed += 1 }
        if !Spike0b.run() { failed += 1 }
        if !Spike0c.run() { failed += 1 }

        print("———")
        if failed == 0 {
            print("Phase 0: all spikes PASSED")
            exit(0)
        } else {
            print("Phase 0: \(failed) spike(s) FAILED")
            exit(1)
        }
    }
}
