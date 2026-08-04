# NPRPC: no client-side route for server-initiated stream chunks (shm, TCP) — RESOLVED

Swift servant + Swift client, two processes, host toolchain 6.3.3, nprpc
`.build_relwith_debinfo`.

## Symptom

`bidi_stream<InputAck, InputEvent> SubscribeInput(arenaId: in string)`.

The stream opens: the client's proxy returns an `NPRPCBidiStream`, the servant's
`subscribeInput` runs, and the client→server direction (`InputAck`) works. The
server→client direction produces nothing. `NPRPCStreamWriter.write` on the
servant side returns success for every chunk; the client's
`for try await … in stream.reader` never yields and never finishes.

Measured with a counter on each side: **209 chunks written, 0 received** over
shm, and the same over TCP.

Over TCP it is not silent — the client logs one line per chunk:

    tcp client: received unexpected response (request_id=0), discarding

Over shm there is no log line at all.

## Cause

`StreamManager::on_chunk_received` has exactly one caller in the tree:

    src/session.cpp:170    ctx_.stream_manager->on_chunk_received(std::move(rx_buffer));

`Session` is the receiving half of a connection, and only some client
connections are one:

| transport | client-side type                                    | is a `Session` |
|-----------|-----------------------------------------------------|----------------|
| WebSocket | `ClientPlainWebSocketSession` / `ClientSSLWebSocketSession` | yes     |
| QUIC      | `QuicClientSession`                                 | yes            |
| TCP       | `SocketConnection`                                  | **no**         |
| shm       | `SharedMemoryConnection`                            | **no**         |

`src/tcp/client_socket_connection.cpp:174-201` is the whole of the TCP client's
receive dispatch: it matches `request_id` against `pending_requests_` and
discards anything that misses. A stream chunk is not a reply to a pending
request, so it always misses — which is what the warning above is. `src/shm/`
contains no reference to `stream_manager` at all.

So server→client streams (`stream<T>` and the read half of `bidi_stream<T, U>`)
work only where the client side is a full `Session`. The integration tests
exercise them under `flags: .ws`, which is why this is not caught there.

## Confirmation

The same binary, same IDL, same servant and same client, with only the object's
transport changed:

    flags: [.shm]   209 written / 0 received
    flags: [.tcp]    22 written / 0 received  + one discard warning per chunk
    flags: [.ws]    209 written / 209 received

## Reproduction

    swift build -c release --product ArenaDemo
    ./.build/release/ArenaDemo host       # terminal 1
    ./.build/release/ArenaDemo produce    # terminal 2

Move the pointer over the renderer's window. On `.webSocket` the app draws a
crosshair at the pointer, highlights the bar under it, and relays out to the
window when it is resized. On `.sharedMemory` the app draws none of that and
prints a line pointing here; the renderer starts logging `client is N input
events behind`, since no `InputAck` comes back either.

Switch with `controlTransport` in `Sources/ArenaDemo/ControlPlane.swift`.

## Second face: the servant never learns the client died

Kill the client. Over shm the servant's `subscribeInput` keeps running and its
subscription is never reaped — `NPRPCStreamWriter.write` reports success for
every chunk, so nothing ever discovers the dead session, and the servant task,
its `AsyncStream` buffer and its broker entry leak per connection.

Over WebSocket the same code tears down correctly, on the first write after the
client goes:

    StreamManager::dispatch_buffer: session is gone, dropping stream_id=…
    SubscribeInput(demo) — subscription 1 ended

So this is the same root cause rather than a separate bug: the send path that
would fail is the one that was never wired up. Worth knowing, though, because
it means a renderer on shm today accumulates dead subscriptions silently.

## Available workaround

A callback object rather than a stream: the client activates its own servant and
passes the reference (`in object`, as `TestUnreliable.RegisterAckHandler` does),
and the renderer calls into it. That is transport-symmetric today, because it
makes the client a server for the return direction rather than asking the
client's connection to accept unsolicited messages. It costs one round trip per
event unless the callback is `[unreliable]`, and it gives up the stream's
credit-based backpressure — which is most of why `SubscribeInput` is a stream
in the first place.
