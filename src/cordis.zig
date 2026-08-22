//! Cordis Native — Zig 0.17 reimplementation of the Cordis meta-framework.
//!
//! Semantic compatibility with TypeScript Cordis, but with native, typed,
//! deterministic composition (see `dev.md`). The public surface is re-exported
//! here; subsystems live under `core/`, `service/`, `event/`, `effect/`,
//! `plugin/` and `io/`.

const std = @import("std");

// Core
pub const Context = @import("core/context.zig").Context;
pub const Scope = @import("core/scope.zig").Scope;
pub const Disposable = @import("core/scope.zig").Disposable;
pub const makeDisposable = @import("core/scope.zig").makeDisposable;
pub const CordisError = @import("core/error.zig").CordisError;

// Service
pub const ServiceRegistry = @import("service/registry.zig").ServiceRegistry;

// Event
pub const EventBus = @import("event/bus.zig").EventBus;
pub const Event = @import("event/event.zig");
pub const SubscribeOptions = @import("event/event.zig").SubscribeOptions;
pub const ReturnOf = @import("event/event.zig").ReturnOf;

// Effect
pub const Scheduler = @import("effect/scheduler.zig").Scheduler;
pub const Effect = @import("effect/effect.zig").Effect;
pub const Task = @import("effect/task.zig").Task;

// Plugin
pub const Plugin = @import("plugin/plugin.zig").Plugin;
pub const PluginManager = @import("plugin/manager.zig").PluginManager;
pub const resolveDependencies = @import("plugin/resolver.zig").resolve;

// I/O
pub const IoContext = @import("io/io.zig").IoContext;

// Loader (phase 2 — dynamic plugins)
pub const loader = @import("loader/loader.zig");
pub const Manifest = @import("loader/manifest.zig").Manifest;
pub const Module = @import("loader/module.zig").Module;

// ABI (phase 2 — C contract, phase 3 — WASM)
pub const abi = @import("abi/c.zig");
pub const wasm = @import("abi/wasm.zig");

test {
    // Pull in every submodule's tests.
    _ = @import("core/scope.zig");
    _ = @import("core/error.zig");
    _ = @import("io/io.zig");
    _ = @import("service/service.zig");
    _ = @import("event/bus.zig");
    _ = @import("event/dispatcher.zig");
    _ = @import("effect/scheduler.zig");
    _ = @import("plugin/resolver.zig");
    _ = @import("plugin/dependency.zig");
    _ = @import("loader/manifest.zig");
    _ = @import("loader/module.zig");
    _ = @import("abi/wasm.zig");
}
