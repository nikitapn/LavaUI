import Foundation
import LavaIDL
import NPRPC

/// What the compositor knows about its own GPU memory.
///
/// Separate from `DesktopSettings` because nothing here is a setting: these are
/// questions, and the answers change on their own. They live in `LavaClient`
/// rather than in the app that asks them so that anything — a debug window, a
/// test, a one-shot CLI — can ask without reimplementing the round trip.
///
/// Only the compositor can answer. It renders every LavaUI surface on the
/// desktop on a single Vulkan device, so the attachments, the glyph atlas and
/// the texture cache behind *all* the windows are one process's memory, and no
/// client can see any of it from inside its own window.
///
/// Synchronous, like `DesktopSettings`, and for the same reason: the call lands
/// on the compositor's event loop and answers in microseconds.
public enum DesktopDiagnostics {
    /// Whether there is a compositor to ask.
    public static var isAvailable: Bool { proxy != nil }

    /// Everything in VRAM, and who asked for it.
    ///
    /// Poll it — a second is a sensible interval. There is deliberately no
    /// stream: allocations happen at window creation, resize and atlas growth,
    /// which is far too bursty to subscribe to and far too rare to need to.
    public static func gpuReport() throws -> GpuReport {
        try call { try await $0.getGpuReport() }
    }

    /// Writes each atlas page under `directory` as a PNG; returns the paths.
    ///
    /// The compositor's filesystem, which for a debug app on the same machine
    /// is also its own — so the returned paths can be handed straight to
    /// `Image(path:)`. An empty result means there were no atlas pages, not
    /// that writing failed; failure throws.
    ///
    /// Slow on purpose: every page is copied off the GPU. Bind it to a button,
    /// never to a timer.
    public static func dumpAtlasImages(
        into directory: String
    ) throws -> [String] {
        // Longer than the two-second default: a page at the device maximum is
        // hundreds of megabytes off the GPU and through a PNG encoder, on the
        // compositor's own loop.
        try call(timeout: 30) { try await $0.dumpAtlasImages(directory: directory) }
    }

    // MARK: - Plumbing

    private static func call<T>(
        timeout: TimeInterval = 10,
        _ body: @escaping @Sendable (Compositor) async throws -> T
    ) throws -> T {
        guard let compositor = proxy else { throw SettingsError.noCompositor }
        return try blockingCall(timeout: timeout) { try await body(compositor) }
    }

    /// The connection this window already has, or one of our own.
    ///
    /// Unlike `DesktopSettings`, this has to work in a process with no window:
    /// the most useful moment to ask what is holding the VRAM is when the
    /// desktop cannot open another window, and a diagnostic that needs a surface
    /// first would be unavailable exactly then. A CLI (`LavaDebug --once`) is
    /// the same case.
    private static var proxy: Compositor? {
        if let inWindow = LavaClient.compositor { return inWindow }
        if let existing = standalone { return existing.0 }
        guard let made = try? connectToCompositor() else { return nil }
        // Generous: `DumpAtlasImages` reads whole atlas pages off the GPU.
        made.0.timeout = 30_000
        // The `Rpc` owns the transport and has to outlive every call made
        // through the proxy, so both are held for the process's lifetime.
        standalone = made
        return made.0
    }

    private nonisolated(unsafe) static var standalone: (Compositor, Rpc)?
}
