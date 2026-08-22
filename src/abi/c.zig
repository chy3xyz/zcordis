//! Cordis Native — C ABI plugin contract (dev.md §18, phase 2).
//!
//! The single source of truth for the C ABI a dynamic plugin must implement.
//! A plugin author writes a shared library exporting:
//!
//! ```c
//! /* from include/cordis_plugin.h */
//! typedef struct { const char* name; const char* version; const char** depends_on; }
//!     CordisPluginManifest;                       // exported data symbol
//! typedef struct CordisHostApi {
//!     int  (*emit)(void* host, const char* name, const void* payload, size_t len);
//!     int  (*subscribe)(void* host, const char* name, void (*cb)(void*, const char*, const void*, size_t), void* userdata);
//!     int  (*unsubscribe)(void* host, int sub_id);
//!     void (*log)(void* host, const char* msg);
//! } CordisHostApi;
//! int  CordisPluginInit(void* host, const CordisHostApi* api);      // 0 == ok
//! void CordisPluginDispose(void* host, const CordisHostApi* api);
//! ```
//!
//! The `host` handle is an opaque pointer to the runtime `Context`; the plugin
//! must treat it as opaque and only interact through `api`. This keeps the
//! ABI stable and lets plugins be written in any C-compatible language.

const std = @import("std");

/// C-style event callback: `(userdata, event_name, payload, payload_len)`.
/// The event name is sentinel-terminated; the payload is `len` raw bytes.
pub const DynCallback = *const fn (
    userdata: ?*anyopaque,
    name: [*:0]const u8,
    payload: ?*const anyopaque,
    len: usize,
) callconv(.c) void;

/// Host functions handed to a plugin. The plugin calls these with the opaque
/// `host` pointer it was given at init.
pub const HostApi = extern struct {
    emit: *const fn (host: ?*anyopaque, name: [*:0]const u8, payload: ?*const anyopaque, len: usize) callconv(.c) c_int,
    subscribe: *const fn (host: ?*anyopaque, name: [*:0]const u8, cb: DynCallback, userdata: ?*anyopaque) callconv(.c) c_int,
    unsubscribe: *const fn (host: ?*anyopaque, sub_id: c_int) callconv(.c) c_int,
    log: *const fn (host: ?*anyopaque, msg: [*:0]const u8) callconv(.c) void,
};

/// The manifest a plugin exports as a data symbol.
pub const CManifest = extern struct {
    name: [*:0]const u8,
    version: [*:0]const u8,
    depends_on: [*:null]const ?[*:0]const u8,
};

pub const InitFn = *const fn (host: ?*anyopaque, api: *const HostApi) callconv(.c) c_int;
pub const DisposeFn = *const fn (host: ?*anyopaque, api: *const HostApi) callconv(.c) void;

pub const manifest_symbol: [:0]const u8 = "CordisPluginManifest";
pub const init_symbol: [:0]const u8 = "CordisPluginInit";
pub const dispose_symbol: [:0]const u8 = "CordisPluginDispose";

/// The corresponding C header, kept in sync with the types above so plugins
/// can be written in C/C++/Rust without Zig.
pub const c_header =
    \\#ifndef CORDIS_PLUGIN_H
    \\#define CORDIS_PLUGIN_H
    \\
    \\#include <stddef.h>
    \\#include <stdint.h>
    \\
    \\#ifdef __cplusplus
    \\extern "C" {
    \\#endif
    \\
    \\typedef struct CordisHostApi CordisHostApi;
    \\
    \\typedef void (*cordis_dyn_cb)(void* userdata, const char* name,
    \\                              const void* payload, size_t len);
    \\
    \\struct CordisHostApi {
    \\    int  (*emit)(void* host, const char* name, const void* payload, size_t len);
    \\    int  (*subscribe)(void* host, const char* name, cordis_dyn_cb cb, void* userdata);
    \\    int  (*unsubscribe)(void* host, int sub_id);
    \\    void (*log)(void* host, const char* msg);
    \\};
    \\
    \\typedef struct {
    \\    const char* name;
    \\    const char* version;
    \\    const char** depends_on; /* null-terminated array */
    \\} CordisPluginManifest;
    \\
    \\extern const CordisPluginManifest CordisPluginManifest;
    \\
    \\int  CordisPluginInit(void* host, const CordisHostApi* api);
    \\void CordisPluginDispose(void* host, const CordisHostApi* api);
    \\
    \\#ifdef __cplusplus
    \\}
    \\#endif
    \\
    \\#endif /* CORDIS_PLUGIN_H */
    \\
;
