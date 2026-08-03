# NPRPC shared-memory reply path: request delivered, reply stranded

Swift servant + Swift client, two processes, `flags: [.shm]`, host 6.3.3,
nprpc `.build_relwith_debinfo`.

## Symptom
Client calls `RegisterFont`; it never returns. Server-side the servant runs to
completion and produces its value (it logs `RegisterFont(...) -> 0`). The
client's `await` on the generated proxy never resumes. Same for a `void`
method (`AttachArena`). Not a timeout — it hangs indefinitely.

## Ruled out
- Not the handler blocking: a servant that returns a constant with no work
  hangs identically.
- Not endpoint selection: `object.selectEndpoint()` after
  `NPRPCObject.fromString(ior)` returns true, and the trace shows a full
  session — `_c2s` and `_s2c` ring buffers created server-side and opened
  client-side, "Connected to listener with dedicated channel".
- Not Swift async-main: the client awaits inside `Task.detached` with a
  semaphore, off the main executor.
- Not the object reference: same reference, same code path, works over TCP.

## Isolating detail
With the object activated `[.tcp]` only, everything works — same IDL, same
servant, same client, same call sequence. With `[.shm]` (or `[.shm, .tcp]`,
since a client offered both always picks shm) it hangs.

It reproduced once and then stopped reproducing across ~10 consecutive runs,
so there may be a race in the s2c path rather than a flat break.

## Reproduction
    swift build -c release
    ./.build/release/ArenaDemo host       # terminal 1
    ./.build/release/ArenaDemo produce    # terminal 2

Flip `useSharedMemory` in `Sources/ArenaDemo/ControlPlane.swift` to `true`.
