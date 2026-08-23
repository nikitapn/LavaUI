import CxxCanvas
import XCTest

@testable import LavaUI

/// Back-pressure between a producer and the process that draws its frames.
///
/// A client publishes a draw list into shared memory and pokes the compositor
/// with an unreliable `Present`; nothing in that made it wait. So a widget that
/// re-dirtied its own frame from inside paint published as fast as it could
/// build a list — ~1000 a second — and the compositor was obliged to keep up.
/// `framesInFlight` is the missing half: the consumer says what it has taken,
/// and the producer paces itself against that.
final class FramePacingTests: XCTestCase {
    /// A windowed app must not pay for any of this. Its renderer is in the
    /// same process and takes every frame synchronously, so there is never
    /// anything in flight and the throttle can never engage.
    func testAnInProcessSinkIsNeverInFlight() throws {
        let editor = try XCTUnwrap(
            Editor.openClient(width: 200, height: 100),
            "client engine failed to open"
        )
        // The default sink, which is the engine's own buffers.
        XCTAssertEqual(
            editor.framesInFlight(window: .main), 0,
            "an in-process sink reported back-pressure it cannot have"
        )
        XCTAssertEqual(
            editor.frames(for: .main).framesInFlight, 0,
            "EngineFrameSink should take the protocol's zero default"
        )
    }

    /// An arena sink reports what the arena knows. Nothing published yet is
    /// not a frame in flight — a producer that thought otherwise would stall
    /// on its own first frame and never draw anything.
    func testAFreshArenaHasNothingInFlight() throws {
        let id = "lavaui-pacing-test-\(getpid())"
        let sink = try XCTUnwrap(
            ArenaFrameSink(id: id), "failed to create the test arena"
        )
        XCTAssertEqual(sink.framesInFlight, 0)
    }

    /// A published frame with nobody to take it stays in flight — which is
    /// the state the throttle waits on, and the state a runaway producer is
    /// permanently in.
    func testAPublishedFrameWithNoConsumerStaysInFlight() throws {
        let id = "lavaui-pacing-unconsumed-\(getpid())"
        let sink = try XCTUnwrap(
            ArenaFrameSink(id: id), "failed to create the test arena"
        )
        let wanted = FrameCapacity(
            commands: 8, glyphs: 0, meshVertices: 0,
            spatialVertices: 0, gradients: 0
        )
        XCTAssertNotNil(sink.beginFrame(minimum: wanted), "no slot claimed")
        sink.commit(wanted)
        XCTAssertEqual(
            sink.framesInFlight, 1,
            "a frame nobody has taken should be in flight"
        )
    }
}
