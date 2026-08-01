# TraceLoom rule assistant

Turns an example log line into a parsing rule, using a local model through
Ollama. Open the "Rule assistant" disclosure under the rules pane, paste a line
you want charted, and press **Suggest rule**.

## Configuration

| variable | default |
| --- | --- |
| `TRACELOOM_OLLAMA_HOST` | `http://localhost:11434` |
| `TRACELOOM_OLLAMA_MODEL` | `gemma4:e4b` |

The model must have the `tools` capability (`ollama show <model>`). Nothing
needs configuring for the default case; if Ollama is not running, the pane
reports the connection error rather than hanging.

## Why it takes turns

The model does not get to declare success. It proposes rules through a
`test_rule` tool, which runs the candidate against real lines from the loaded
log and reports what each capture group actually contained:

```
REJECTED — matches 2 of 4 sample lines, extracts a point from 0.
  "19:16:15.280 NetworkMetrics inboundKbps:8400 outboundKbps:3200"
    -> matched, but there is no capture group 9 to take the value from
```

`submit_rule` re-runs the same check and refuses anything that fails, so a
confident wrong answer becomes another round rather than a rule. The gate is
`RuleCheck.isAcceptable`: the rule must parse, match at least one line, and
extract a point from *every* line it matches — a rule that matches ten lines
and extracts from three is not a working rule, it is one that fills the
diagnostics pane.

Because the checker is the arbiter, the assistant's usefulness does not depend
on the model being good at regex. It depends on the model being able to read a
failure and try again, which small models do well.

The loop stops after 8 rounds. A rule already rejected is fed back as such, so
a model that starts repeating itself is told so explicitly.

## Threading

The run happens on a `Task`; the UI thread is never blocked, and was measured at
a worst-case 18.8ms main-loop round-trip across 885 samples during a live run.

Results reach `@State` only through `MainQueue` — a worker may not write view
state directly, because `withObservationTracking`'s `onChange` fires on the
writing thread and would race the run loop's invalidation. See the `MainQueue`
doc comment.

Redraw requests are coalesced. A reasoning stream is thousands of deltas, and
marking the body dirty per delta would rebuild the view — on a large log, an
expensive view — per token. `AssistantSession` posts a refresh only when one is
not already pending, capping the cost at one rebuild per frame.

## Reasoning models

Every tool-capable model on the reference machine thinks before its first tool
call, and during that time Ollama's `content` stays empty — ~110s for qwen3.5,
~25s for gemma4:e4b. `ChatDelta` reports `.thinking` separately from `.content`
so the pane can show the model working without presenting its scratch work as
the answer. Without that the window looks hung for the entire think.

## Testing

`RuleAssistantTests` drives the loop against a scripted `ChatBackend`, including
the cases that matter: a wrong rule comes back with the checker's reason, a
submitted-but-failing rule is refused, a repeated rule is called out, and the
loop gives up rather than spinning.

There is also an opt-in live test:

```
OLLAMA_MODEL=gemma4:e4b swift test --filter liveOllamaSuggestsARule
```

It covers what only a real model exercises — that the streaming NDJSON decodes,
that tool calls arrive in the expected shape, and that a given model will use
the tools at all.
