# NPRPC: server-initiated stream chunks over shm — resolved

Kept as a record, because the failure was invisible in exactly the way that
wastes an afternoon: the stream opened, every write reported success, and the
reader simply never yielded.

## What it was

`bidi_stream<InputAck, InputEvent> SubscribeInput(arenaId: in string)`, Swift
servant and Swift client, two processes.

Client→server (`InputAck`) worked. Server→client produced nothing:
`NPRPCStreamWriter.write` returned success for every chunk and the client's
`for try await … in stream.reader` never yielded and never finished.
**209 chunks written, 0 received.**

`StreamManager::on_chunk_received` had one caller, `src/session.cpp`, and
`Session` is the receiving half of a connection — which only some *client*
connections were:

| transport | client-side type                                           | was a `Session` |
|-----------|------------------------------------------------------------|-----------------|
| WebSocket | `ClientPlainWebSocketSession` / `ClientSSLWebSocketSession` | yes             |
| QUIC      | `QuicClientSession`                                        | yes             |
| TCP       | `SocketConnection`                                         | no              |
| shm       | `SharedMemoryConnection`                                   | no              |

TCP's client receive dispatch matched `request_id` against `pending_requests_`
and discarded the miss, one `received unexpected response (request_id=0),
discarding` per chunk; `src/shm/` referenced `stream_manager` nowhere at all.
The integration tests exercised streams under `flags: .ws`, which is why this
did not show up there.

Same binary, same servant, same client, only the object's transport changed:

    flags: [.shm]   209 written / 0 received
    flags: [.tcp]    22 written / 0 received  + one discard warning per chunk
    flags: [.ws]    209 written / 209 received

## Fixed

nprpc now routes server-initiated chunks into a shm client's stream manager.
Verified end to end on `[.shm]`: pointer motion, clicks, cross-process
hit-testing and resize all arrive, and `InputAck` comes back — the renderer's
lag counter sits at zero while the client keeps up.

## Still open: a dead client is not noticed over shm

Kill the producer and keep moving the pointer. The servant's `subscribeInput`
keeps running and its subscription is never reaped — `write` reports success
for every chunk to a peer that no longer exists, so nothing discovers the dead
session. Confirmed with ~200 writes after the client's death: no teardown, and
the renderer's lag counter is the only thing that notices
(`client is 84 input events behind`).

Under WebSocket this reported itself on the first write after the client went:

    StreamManager::dispatch_buffer: session is gone, dropping stream_id=…
    SubscribeInput(demo) — subscription 1 ended

So a long-running renderer on shm accumulates one leaked servant task,
`AsyncStream` buffer and broker entry per client that dies. Bounded in
practice, and the lag counter makes it visible, but it wants the same
"session is gone" signal the other transports have.
