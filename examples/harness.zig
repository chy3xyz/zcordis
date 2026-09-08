//! Cordis Native — DeepSeek-Harness-style agent runtime example.
//!
//! Run with `zig build run-harness`.
//!
//! DeepSeek Harness (dsh) is an open-source Agent runtime built on Cordis whose
//! motto is "everything is a plugin": the model adapter, the tool registry, the
//! system prompt, and the agent loop itself are all Cordis plugins contributing
//! services and typed events to one shared `ctx`. There is no privileged kernel
//! — you extend the harness by mounting a plugin beside the others, and all of
//! its registrations are reversible side effects undone on unload.
//!
//! zcordis reimplements that same Cordis model, so this example reproduces the
//! dsh turn flow as faithfully as the native API allows:
//!
//! ```text
//! turn/start
//!   agent/pre-step   (waterfall: rewrite / inject system prompt)
//!   agent/request -> llm/stream   (waterfall: model adapter produces reply)
//!   tool/call -> tools/pre-execute -> tools/execute -> tools/post-execute
//!   agent/turn-stopping  (serial: may close the turn)
//! turn/end
//! ```
//!
//! In dsh the waterfall listeners call `next()` to delegate; in zcordis the
//! analogous idiom is a `waterfall` whose handlers mutate a shared accumulator
//! carried in the event payload (a `*Conversation` pointer), then return `void`.

const std = @import("std");
const cordis = @import("cordis");

// ── Shared vocabulary ────────────────────────────────────────────────────
// A chat message. Roles are plain strings so the example stays language-neutral.
const Message = struct {
    role: []const u8, // "system" | "user" | "assistant" | "tool"
    content: []const u8,
};

// The running conversation. This is the mutable accumulator that waterfall
// handlers reach through a pointer in their event payload — the zcordis
// equivalent of dsh's "call next() with a transformed value".
const Conversation = struct {
    alloc: std.mem.Allocator,
    messages: std.ArrayList(Message),
    reply: []const u8 = "", // last assistant reply (set by the model adapter)
    final: []const u8 = "", // final answer once the turn stops
    turns: usize = 0,
    tool_pending: ?ToolCall = null, // set by the model adapter, consumed by the loop

    fn init(alloc: std.mem.Allocator) Conversation {
        return .{ .alloc = alloc, .messages = .empty };
    }
    fn deinit(self: *Conversation) void {
        for (self.messages.items) |m| {
            self.alloc.free(m.role);
            self.alloc.free(m.content);
        }
        self.messages.deinit(self.alloc);
        if (self.reply.len > 0) self.alloc.free(self.reply);
        if (self.final.len > 0) self.alloc.free(self.final);
    }
    // `push`/`unshift` take ownership of the slices they are given (they dupe
    // into the conversation arena), so `deinit` can free every message. Callers
    // that allocate a transient buffer just pass it in and let push own the copy.
    fn push(self: *Conversation, role: []const u8, content: []const u8) !void {
        try self.messages.append(self.alloc, .{
            .role = try self.alloc.dupe(u8, role),
            .content = try self.alloc.dupe(u8, content),
        });
    }
    /// Insert at the front (used to place the system prompt before the user
    /// turn). Order matters for the model's view of the conversation.
    fn unshift(self: *Conversation, role: []const u8, content: []const u8) !void {
        try self.messages.insert(self.alloc, 0, .{
            .role = try self.alloc.dupe(u8, role),
            .content = try self.alloc.dupe(u8, content),
        });
    }
};

/// Free a pending tool call (its name/input are duped into the conversation
/// arena) before it is replaced or cleared.
fn convFreeToolPending(conv: *Conversation) void {
    if (conv.tool_pending) |tc| {
        conv.alloc.free(tc.name);
        conv.alloc.free(tc.input);
        conv.tool_pending = null;
    }
}

// What a model adapter decides to do. Either it answers directly, or it asks
// the agent loop to call a tool first (dsh's tool-call intent).
const ModelDecision = struct {
    reply: []const u8,
    tool_call: ?ToolCall = null,
};
const ToolCall = struct {
    name: []const u8,
    // The expression string handed to the tool, owned by the conversation.
    input: []const u8,
};

// ── Core services (each contributed by a different plugin) ────────────────

// ctx.llm — the model-adapter seam. A plugin registers the active adapter.
const LLM = struct {
    alloc: std.mem.Allocator,
    // Inspect the conversation and decide a reply / tool call. Canned here,
    // but in dsh this delegates to a real provider (DeepSeek, OpenAI, local…).
    decide: *const fn (*LLM, *const Conversation) ModelDecision,
};

// ctx.tools — the scoped tool registry and gated execution pipeline.
const ToolRegistry = struct {
    const Entry = struct {
        name: []const u8,
        schema: []const u8,
        // Tools write their result into a caller-provided scratch buffer and
        // return the filled slice — no allocation, no lifetime hazard.
        run: *const fn (*const ToolCall, []u8) []const u8,
    };
    alloc: std.mem.Allocator,
    entries: std.StringArrayHashMapUnmanaged(Entry) = .{},

    fn register(
        self: *ToolRegistry,
        name: []const u8,
        schema: []const u8,
        run: *const fn (*const ToolCall, []u8) []const u8,
    ) !void {
        try self.entries.put(self.alloc, try self.alloc.dupe(u8, name), .{
            .name = try self.alloc.dupe(u8, name),
            .schema = try self.alloc.dupe(u8, schema),
            .run = run,
        });
    }
    fn get(self: *ToolRegistry, name: []const u8) ?Entry {
        return self.entries.get(name);
    }
};

// ctx.systemPrompt — assembles the system prompt from fragments.
const SystemPrompt = struct {
    fragments: std.ArrayListUnmanaged([]const u8) = .empty,
    alloc: std.mem.Allocator,
    fn add(self: *SystemPrompt, frag: []const u8) !void {
        try self.fragments.append(self.alloc, frag);
    }
    fn render(self: *SystemPrompt, alloc: std.mem.Allocator) ![]const u8 {
        var buf: [4096]u8 = undefined;
        var n: usize = 0;
        for (self.fragments.items) |f| {
            const need = f.len + 1;
            // Surface overflow instead of silently truncating the prompt.
            if (n + need > buf.len) return error.SystemPromptTooLong;
            @memcpy(buf[n .. n + f.len], f);
            n += f.len;
            buf[n] = '\n';
            n += 1;
        }
        return try alloc.dupe(u8, buf[0..n]);
    }
};

// ctx.agent — the active agent registry / driver interface.
const Agent = struct {};

/// Drive one conversation through the agent loop: a waterfall of
/// `agent/pre-step` → `agent/request` → (tool calls) → `agent/turn-stopping`.
fn runAgentTurn(_: *Agent, ctx: *cordis.Context, conv: *Conversation) !void {
    // One plugin owns the loop; it drives the waterfall pipeline below.
    while (conv.turns < 8) {
        conv.turns += 1;

        // agent/pre-step + agent/request + llm/stream — all one waterfall.
        // Each handler mutates `conv` through the payload pointer.
        var pre = AgentPreStep{ .conv = conv };
        try ctx.waterfall(AgentPreStep, &pre, {});

        var req = AgentRequest{ .conv = conv };
        try ctx.waterfall(AgentRequest, &req, {});

        // Did the model ask for a tool?
        if (conv.tool_pending) |tc| {
            var te = ToolExecute{ .conv = conv, .call = tc };
            try ctx.waterfall(ToolExecute, &te, {});
            convFreeToolPending(conv);
            continue; // feed the tool result back into another request
        }

        // agent/turn-stopping — bail event; a truthy return closes it.
        var stop = TurnStopping{ .conv = conv };
        const should_stop = (try ctx.bail(TurnStopping, &stop)) orelse false;
        if (should_stop) break;
    }
}

// ── Events (typed; waterfall handlers mutate the shared Conversation) ─────

// agent/pre-step: rewrite / inject the system prompt before the request.
const AgentPreStep = struct {
    conv: *Conversation,
};

// agent/request + llm/stream: the model adapter produces the reply.
const AgentRequest = struct {
    conv: *Conversation,
};

// tools/pre-execute -> tools/execute -> tools/post-execute, one waterfall.
const ToolExecute = struct {
    conv: *Conversation,
    call: ToolCall,
};

// agent/turn-stopping: serial; return true to close the turn.
const TurnStopping = struct {
    conv: *Conversation,
    pub const Return = bool;
};

// ── Plugins ───────────────────────────────────────────────────────────────
// Every product component is a plugin. They are loaded in dependency order and
// torn down deterministically — exactly the dsh "everything is a plugin" idea.

// 1. System prompt fragment contributor.
const SystemPromptPlugin = struct {
    fn init(scope: *cordis.Scope) !void {
        const ra = scope.runtime.root.alloc();
        var sp = try ra.create(SystemPrompt);
        sp.* = .{ .alloc = ra };
        try sp.add("You are a concise assistant that can use tools.");
        try sp.add("When you need arithmetic, call the 'calculator' tool.");
        // Contribute to the shared root ctx (dsh: "plugins contribute services
        // to a shared context"), so every other plugin and the host can see it.
        _ = try scope.runtime.root.provide(SystemPrompt, "systemPrompt", sp.*, null);
    }
};

// 2. Model adapter — registers the active LLM on ctx.llm.
const ModelAdapterPlugin = struct {
    fn decide(_: *LLM, conv: *const Conversation) ModelDecision {
        // Canned policy: if the last user message asks to calculate, extract
        // the "a + b" expression and emit a tool call; otherwise answer from a
        // tiny script. A real adapter would call a model provider here.
        const last = conv.messages.items[conv.messages.items.len - 1];
        const plus = std.mem.indexOf(u8, last.content, "+");
        if (plus != null and std.mem.indexOf(u8, last.content, "calculate") != null) {
            // Isolate the two integer runs immediately around the '+'.
            const s = last.content;
            const p = plus.?;
            // Left operand: back up over any spaces, then over digits.
            var ls = p;
            while (ls > 0 and s[ls - 1] == ' ') ls -= 1;
            while (ls > 0 and std.ascii.isDigit(s[ls - 1])) ls -= 1;
            // Right operand: forward over spaces, then digits.
            var rs = p + 1;
            while (rs < s.len and s[rs] == ' ') rs += 1;
            var re = rs;
            while (re < s.len and std.ascii.isDigit(s[re])) re += 1;
            // `input` is a slice of the user message (owned by the
            // conversation), so it needs no separate allocation.
            return .{
                .reply = "I will compute that for you.",
                .tool_call = .{ .name = "calculator", .input = s[ls..re] },
            };
        }
        return .{ .reply = "The answer is ready." };
    }
    fn init(scope: *cordis.Scope) !void {
        const ra = scope.runtime.root.alloc();
        const llm = try ra.create(LLM);
        llm.* = .{ .alloc = ra, .decide = decide };
        _ = try scope.runtime.root.provide(LLM, "llm", llm.*, null);
    }
};

// 3. Tools — registers the tool registry and a calculator tool.
const ToolsPlugin = struct {
    fn calc(call: *const ToolCall, buf: []u8) []const u8 {
        // Minimal "a + b" evaluator so the tool does real work.
        const s = call.input;
        const plus = std.mem.indexOf(u8, s, "+") orelse return "error: no '+'";
        const a = std.fmt.parseInt(i64, std.mem.trim(u8, s[0..plus], " "), 10) catch return "error";
        const b = std.fmt.parseInt(i64, std.mem.trim(u8, s[plus + 1 ..], " "), 10) catch return "error";
        return std.fmt.bufPrint(buf, "{}", .{a + b}) catch "error";
    }
    fn init(scope: *cordis.Scope) !void {
        // Allocate the registry and its contents in the root arena so they
        // outlive this plugin's own scope (which is disposed before root).
        const ra = scope.runtime.root.alloc();
        var reg = try ra.create(ToolRegistry);
        reg.* = .{ .alloc = ra };
        try reg.register("calculator", "add two integers: 'a + b'", calc);
        _ = try scope.runtime.root.provide(ToolRegistry, "tools", reg.*, null);
    }
};

// 4. Agent loop — provides the Agent and wires the waterfall listeners.
const AgentLoopPlugin = struct {
    // agent/pre-step: inject the rendered system prompt as message[0].
    const onPreStep = struct {
        fn call(scope: *cordis.Scope, e: *const AgentPreStep) !void {
            const conv = e.conv;
            // Inject the system prompt exactly once (idempotent across turns).
            for (conv.messages.items) |m| {
                if (std.mem.eql(u8, m.role, "system")) return;
            }
            const sp = scope.get(SystemPrompt, "systemPrompt") orelse return error.NoSystemPrompt;
            const rendered = sp.render(conv.alloc) catch return;
            try conv.unshift("system", rendered);
            conv.alloc.free(rendered); // unshift took its own copy
        }
    }.call;

    // agent/request + llm/stream: call the adapter, set the reply.
    const onRequest = struct {
        fn call(scope: *cordis.Scope, e: *const AgentRequest) !void {
            const conv = e.conv;
            const llm = scope.get(LLM, "llm") orelse return error.NoLLM;
            const d = llm.decide(llm, conv);
            if (conv.reply.len > 0) conv.alloc.free(conv.reply);
            conv.reply = try conv.alloc.dupe(u8, d.reply);
            try conv.push("assistant", d.reply);
            if (d.tool_call) |tc| {
                convFreeToolPending(conv);
                conv.tool_pending = .{ .name = try conv.alloc.dupe(u8, tc.name), .input = try conv.alloc.dupe(u8, tc.input) };
            }
        }
    }.call;

    // tools/pre-execute -> tools/execute -> tools/post-execute.
    const onTool = struct {
        fn call(scope: *cordis.Scope, e: *const ToolExecute) !void {
            const conv = e.conv;
            const reg = scope.get(ToolRegistry, "tools") orelse return error.NoTools;
            const entry = reg.get(e.call.name) orelse return error.UnknownTool;
            var scratch: [32]u8 = undefined;
            const result = entry.run(&e.call, &scratch);
            // `result` points into `scratch` (valid for this handler call);
            // embed it into owned transcript messages (push dupes them).
            const tool_msg = try std.fmt.allocPrint(conv.alloc, "{s} -> {s}", .{ e.call.name, result });
            try conv.push("tool", tool_msg);
            conv.alloc.free(tool_msg);
            const result_msg = try std.fmt.allocPrint(conv.alloc, "tool result: {s}", .{result});
            try conv.push("user", result_msg);
            conv.alloc.free(result_msg);
        }
    }.call;

    // agent/turn-stopping: stop once we have a final answer (no pending tool).
    const onStop = struct {
        fn call(_: *cordis.Scope, e: *const TurnStopping) !bool {
            const conv = e.conv;
            if (conv.tool_pending == null and conv.turns >= 2) {
                conv.final = try conv.alloc.dupe(u8, conv.reply);
                return true;
            }
            return false;
        }
    }.call;

    fn init(scope: *cordis.Scope) !void {
        // Listeners are created on this plugin's own scope (so they are revoked
        // on plugin unload) but marked `global` so they fire for events emitted
        // from the shared root ctx — the dsh "extension point" pattern.
        _ = try scope.on(AgentPreStep, onPreStep, .{ .global = true });
        _ = try scope.on(AgentRequest, onRequest, .{ .global = true });
        _ = try scope.on(ToolExecute, onTool, .{ .global = true });
        _ = try scope.on(TurnStopping, onStop, .{ .priority = 1, .global = true });

        const agent = try scope.runtime.root.alloc().create(Agent);
        agent.* = .{};
        _ = try scope.runtime.root.provide(Agent, "agent", agent.*, null);
    }
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const alloc = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    var ctx = try cordis.Context.init(alloc);
    defer ctx.deinit();

    // Boot the harness: mount the plugins (dependency-ordered, like dsh
    // profiles/bundles composed at startup).
    try ctx.load(.{ .name = "system-prompt", .init = SystemPromptPlugin.init });
    try ctx.load(.{ .name = "llm", .init = ModelAdapterPlugin.init });
    try ctx.load(.{ .name = "tools", .init = ToolsPlugin.init, .depends_on = &.{"llm"} });
    try ctx.load(.{ .name = "agent-loop", .init = AgentLoopPlugin.init, .depends_on = &.{ "llm", "tools" } });
    try ctx.start();

    // Drive a conversation through the plugin-composed agent loop.
    var conv = Conversation.init(alloc);
    defer conv.deinit();
    try conv.push("user", "please calculate 2 + 3");

    const agent = ctx.get(Agent, "agent").?;
    try runAgentTurn(agent, ctx, &conv);

    std.debug.print("[harness] turns run: {}\n", .{conv.turns});
    std.debug.print("[harness] final answer: {s}\n", .{conv.final});
    std.debug.print("[harness] transcript:\n", .{});
    for (conv.messages.items) |m| {
        std.debug.print("  {s}: {s}\n", .{ m.role, m.content });
    }
}
