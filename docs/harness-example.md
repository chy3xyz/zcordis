# Example: a DeepSeek-Harness-style agent runtime

`examples/harness.zig` (run with `zig build run-harness`) is a worked example
that mirrors the architecture of [DeepSeek Harness](https://github.com/deepseek-ai)
(dsh) — an open-source Agent runtime built **on Cordis** whose motto is
"everything is a plugin."

Because `zcordis` reimplements the same Cordis model (typed `waterfall`/`serial`
dispatch, scope-aware services, dependency-ordered plugins), the example
reproduces dsh's core ideas on native Zig:

- The **model adapter**, the **tool registry**, the **system prompt**, and the
  **agent loop** are all Cordis plugins contributing services and events to one
  shared `ctx`. There is no privileged kernel.
- The agent turn is driven by a pipeline of **waterfall events**
  (`agent/pre-step`, `agent/request`, `llm/stream`, `tools/*`) that plugins
  intercept and augment.
- Teardown is deterministic: unloading a plugin revokes every service and
  listener it registered.

## The dsh turn flow, and how it maps to zcordis

```text
turn/start
  agent/pre-step     waterfall: inject / rewrite the system prompt
  agent/request      waterfall: the model adapter produces a reply (llm/stream)
  tool/call -> tools/pre-execute -> tools/execute -> tools/post-execute
  agent/turn-stopping  serial (bail): a truthy return closes the turn
turn/end
```

In dsh the waterfall listeners call `next()` to delegate control downstream.
In zcordis there is no `next()` callback; the equivalent idiom is a `waterfall`
whose handlers **mutate a shared accumulator** carried in the event payload
(the `*Conversation` pointer) and the dispatcher chains them in priority order.

## Plugins in the example

| Plugin | Contributes (service) | Registers (events) |
| --- | --- | --- |
| `SystemPromptPlugin` | `ctx.systemPrompt` — prompt fragments | — |
| `ModelAdapterPlugin` | `ctx.llm` — a canned `decide` policy | — |
| `ToolsPlugin` | `ctx.tools` — a `calculator` tool | — |
| `AgentLoopPlugin` | `ctx.agent` — the driver | `agent/pre-step`, `agent/request`, `tools/*`, `agent/turn-stopping` |

Services are contributed to the **shared root context** (`scope.runtime.root.provide(...)`)
so every other plugin and the host can see them — exactly dsh's "plugins
contribute services to a shared ctx". Event listeners are created on each
plugin's own scope (so they are revoked on plugin unload) but marked
`global = true` so they fire for events emitted from the root — the dsh
"mount an extension point beside the others" pattern.

## How to use and extend the harness

Everything below is a recipe you can drop into `examples/harness.zig`.

### Run it

```sh
zig build run-harness
```

Expected output (a two-turn agent loop that calls a tool):

```text
[harness] turns run: 2
[harness] final answer: The answer is ready.
[harness] transcript:
  system: You are a concise assistant that can use tools.
          When you need arithmetic, call the 'calculator' tool.
  user: please calculate 2 + 3
  assistant: I will compute that for you.
  tool: calculator -> 5
  user: tool result: 5
  assistant: The answer is ready.
```

### 1. Add a tool

Tools are registered on the `ctx.tools` registry (`ToolRegistry`). A tool
receives a `*ToolCall` and writes its result into a caller-provided scratch
buffer — **no allocation**, so there is no buffer to free or leak:

```zig
fn now(_: *const ToolCall, buf: []u8) []const u8 {
    const t = std.time.timestamp();
    return std.fmt.bufPrint(buf, "{}", .{t}) catch "error";
}

// inside ToolsPlugin.init, after registering `calculator`:
try reg.register("clock", "return the current unix timestamp", now);
```

The agent loop picks it up automatically: whenever the model adapter emits a
`ToolCall{ .name = "clock", .input = "..." }`, the `tools/*` waterfall executes
it and feeds the result back as a `user` message.

### 2. Swap the model adapter

The model adapter is the `ctx.llm` service. It implements one function:

```zig
fn decide(self: *LLM, conv: *const Conversation) ModelDecision {
    const last = conv.messages.items[conv.messages.items.len - 1];
    // ... inspect `conv`, return either a direct reply or a ToolCall ...
    return .{ .reply = "..." };
    // or: return .{ .reply = "...", .tool_call = .{ .name = "calculator", .input = "2 + 3" } };
}
```

To use a real provider, replace `ModelAdapterPlugin.init` with one that points
`llm.decide` at a function that calls out to DeepSeek / OpenAI / a local model
and returns a `ModelDecision`. The rest of the pipeline (pre-step, tool
execution, turn-stopping) is unchanged — that is the point of the seam.

You can even mount a *second* adapter plugin and let it overwrite `ctx.llm`:
because services are keyed by name, the last plugin started wins. (The example
keeps a single adapter for clarity.)

### 3. Add an event listener (an extension point)

This is the dsh "mount a plugin beside the others" move. Any plugin can observe
or rewrite the conversation by subscribing to the waterfall events. For example,
a logger that watches the assistant's replies:

```zig
const onLog = struct {
    fn call(_: *cordis.Scope, e: *const AgentRequest) !void {
        // AgentRequest fires after the model produces a reply; read it from
        // the shared conversation.
        std.debug.print("[log] assistant said: {s}\n", .{e.conv.reply});
    }
}.call;

// inside any plugin's init:
_ = try scope.on(AgentRequest, onLog, .{ .global = true, .priority = -1 });
```

Key points:

- `.global = true` — events are emitted from the root `ctx`, so a listener on a
  plugin scope must opt out of scope filtering to receive them.
- `.priority` — higher runs first; negative priorities run *after* the built-in
  handlers, positive ones *before*.
- Returning normally lets the waterfall continue; there is no `next()` to call.

### 4. Add a whole plugin

A plugin is a struct with an `init(scope)` that contributes a service and/or
registers listeners. Load it in dependency order in `main`:

```zig
const GuardPlugin = struct {
    fn init(scope: *cordis.Scope) !void {
        // contribute a service, register listeners, etc.
        _ = scope; // (no-op placeholder)
    }
};

// in main, before ctx.start():
try ctx.load(.{ .name = "guard", .init = GuardPlugin.init, .depends_on = &.{"agent-loop"} });
```

`depends_on` guarantees `GuardPlugin.init` runs *after* `agent-loop` has
registered its listeners, so it can subscribe ahead of or behind them via
priority. On `ctx.deinit()` the plugin's scope is disposed and every listener it
registered is revoked — automatically.

### 5. Query a service from anywhere

Any plugin or the host can read a shared service by walking the scope tree:

```zig
const tools = scope.get(ToolRegistry, "tools") orelse return error.NoTools;
const entry = tools.get("calculator") orelse return error.UnknownTool;
```

`get` walks *upward* to the root, so a service provided on the root context is
visible to every plugin and to the host. (This is why the example provides
services on `scope.runtime.root` rather than on the plugin's own scope — see
the lifetime notes below.)

### 6. Change when the turn stops

The stop decision is a `bail` event, `agent/turn-stopping`, whose handler
returns `bool`. Replace the condition to suit your agent:

```zig
const onStop = struct {
    fn call(_: *cordis.Scope, e: *const TurnStopping) !bool {
        // stop once the model has produced a non-tool reply AND we have at
        // least one tool result in the transcript:
        const has_tool_result = for (e.conv.messages.items) |m| {
            if (std.mem.eql(u8, m.role, "tool")) break true;
        } else false;
        return e.conv.tool_pending == null and has_tool_result;
    }
}.call;
```

Because it is a `bail`, the first listener to return `true` wins and the turn
closes.

## Core API patterns used

**Typed waterfall with a mutable accumulator** (the dsh `next()` equivalent):

```zig
const AgentPreStep = struct { conv: *Conversation };

const onPreStep = struct {
    fn call(scope: *cordis.Scope, e: *const AgentPreStep) !void {
        // ... inject system prompt into e.conv ...
    }
}.call;

_ = try scope.on(AgentPreStep, onPreStep, .{ .global = true });

// the loop drives the pipeline; each handler transforms e.conv in turn
try ctx.waterfall(AgentPreStep, &pre, {});
```

**Serial / bail for a stop decision** (dsh's `agent/turn-stopping`):

```zig
const TurnStopping = struct {
    conv: *Conversation,
    pub const Return = bool,   // enables value-returning dispatch
};

const onStop = struct {
    fn call(_: *cordis.Scope, e: *const TurnStopping) !bool {
        if (e.conv.tool_pending == null and e.conv.turns >= 2) return true;
        return false;
    }
}.call;

// first truthy result short-circuits and is returned
const should_stop = (try ctx.bail(TurnStopping, &stop)) orelse false;
```

**A tool that writes into a caller buffer** (no allocation, no lifetime
hazard — see the note below):

```zig
fn calc(call: *const ToolCall, buf: []u8) []const u8 {
    // ... parse "a + b" ...
    return std.fmt.bufPrint(buf, "{}", .{a + b}) catch "error";
}
```

## Two lifetime notes worth copying

These caused real leaks while building the example; both are general lessons
for `zcordis` code:

1. **Service values are copied on `provide`.** `scope.provide(T, name, value, ...)`
   stores `value` by value. If that struct owns heap buffers (e.g. an
   `ArrayList` whose items live in a child scope's arena), those buffers dangle
   once the child scope is disposed. Allocate capability state in the **root
   arena** (`scope.runtime.root.alloc()`) so it outlives plugin scopes.

2. **Decide who owns a buffer at each hand-off.** In the example `Conversation.push`
   takes ownership by duping into the conversation arena; callers that allocate a
   transient buffer (e.g. `std.fmt.allocPrint`) must free it *after* pushing,
   otherwise the original is orphaned. Conversely, `deinit` frees every message,
   so do not store static string literals and then free them.

## Where to go next

- [Getting Started](getting-started.md) — Context, Scope, services, events.
- [Plugins](plugins.md) — the three plugin formats and loader teardown order.
- [Effects](effects.md) — cancellable background work tied to a scope.
- [WASM interpreter reference](wasm-interpreter.md) — the built-in interpreter.
