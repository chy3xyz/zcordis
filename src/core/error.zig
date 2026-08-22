//! Cordis Native — error model.
//!
//! Cordis distinguishes a small set of runtime errors from ordinary
//! application errors. Zig has no exceptions, so we model them as an error
//! set plus helper constructors. Application plugins return their own
//! `anyerror!` values; Cordis-internal failures use `CordisError`.

pub const CordisError = error{
    /// Tried to create an effect on a scope that is not active
    /// (already disposed or never activated).
    InactiveEffect,
    /// A dependency cycle was detected while resolving the plugin graph.
    DependencyCycle,
    /// A required service could not be resolved from the scope chain.
    ServiceNotFound,
    /// A plugin declared a dependency that no registered plugin provides.
    MissingDependency,
    /// Plugin initialization failed; the error is wrapped so teardown can
    /// still proceed for sibling plugins.
    PluginInitFailed,
    /// An effect could not be cancelled (already completed).
    EffectCompleted,
};

pub fn cycleError() CordisError {
    return CordisError.DependencyCycle;
}

test "cordis error set is usable" {
    const e: CordisError = CordisError.ServiceNotFound;
    try std.testing.expectEqual(CordisError.ServiceNotFound, e);
}

const std = @import("std");
