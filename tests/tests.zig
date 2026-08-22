//! Cordis Native — integration test aggregator.
//!
//! These tests exercise the *public* `cordis` API end-to-end (cross-cutting
//! behaviour that the per-module inline `@import` tests do not cover). Each
//! `tests/*.zig` file is pulled in here; the build wires this file as its own
//! test root module with the `cordis` module imported.

test {
    _ = @import("scope_test.zig");
    _ = @import("service_test.zig");
    _ = @import("event_test.zig");
    _ = @import("effect_test.zig");
    _ = @import("plugin_test.zig");
    _ = @import("loader_test.zig");
    _ = @import("wasm_loader_test.zig");
    _ = @import("wasm_fuzz.zig");
}
