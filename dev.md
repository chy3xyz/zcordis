对，**上一条确实搞错了对象**。你说的是 [cordiverse/cordis](https://github.com/cordiverse/cordis?utm_source=chatgpt.com)，不是我上一条提到的另一个同名项目。

我重新核对了源码仓库：Cordis 的定位是 **“Meta-Framework of Spatiotemporal Composability（时空可组合性元框架）”**，核心标签是 `effect / framework / nodejs / plugin`，目前仍在积极开发，官方明确说 API 尚未稳定。仓库目前约 550 commits、6K stars。([GitHub][1])

而且 npm 当前已经到 `4.0.0-rc.7`，所以这次如果要重写，应该以 **Cordis 3.x/4.x 的真实架构思想** 为目标，而不是“Agent Cognitive Engine”。([npm][2])

下面重新给你一套 **TypeScript Cordis → Zig 0.17 Native Cordis** 的技术方案。

---

# 一、先明确：Cordis 真正的核心是什么

Cordis 不是传统 Web Framework。

它的核心思想可以概括成：

> **Context + Scope + Effect + Event + Service + Plugin + Dependency**

也就是说：

```text
Plugin
   │
   ▼
Context
   │
   ├── Service
   ├── Event
   ├── Effect
   ├── Scope
   └── Dependency
```

Cordis 最有价值的地方，其实是它把：

> **依赖关系、生命周期、事件系统、插件组合**

统一进一个运行时模型。

所以 Zig 重写时，绝不能简单做：

```text
TypeScript class
        ↓
Zig struct
```

应该做的是：

> **重新实现 Cordis 的运行时语义。**

---

# 二、我建议把 Zig 版本定位成

## `Cordis Native`

```text
Cordis TypeScript
       │
       │ semantic compatibility
       ▼
┌───────────────────────────┐
│       Cordis Native       │
│          Zig 0.17         │
├───────────────────────────┤
│ Context                   │
│ Scope                     │
│ Service                   │
│ Plugin                    │
│ Event                     │
│ Effect                    │
│ Dependency                │
│ Lifecycle                 │
│ Scheduler                 │
└───────────────────────────┘
```

最终目标：

```text
Node.js Cordis
      ↓
Zig Cordis
      ↓
Native Runtime
```

但不是要求 100% API 一模一样。

应该做到：

> **Semantic Compatibility + Native API**

---

# 三、先理解 Cordis 的核心抽象

我认为至少需要还原以下 8 个核心概念：

```text
Context
Scope
Plugin
Service
Event
Effect
Dependency
Lifecycle
```

可以形成：

```text
                       Context
                          │
             ┌────────────┼────────────┐
             │            │            │
             ▼            ▼            ▼
          Scope        Service       Event
             │            │            │
             ▼            ▼            ▼
          Plugin       Effect      Dispatcher
             │
             ▼
        Dependency
             │
             ▼
         Lifecycle
```

---

# 四、Zig 的核心 Context

TypeScript 中大量能力依赖对象、继承、动态属性和函数闭包。

Zig 不能照搬。

建议：

```zig
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    registry: Registry,
    events: EventBus,
    effects: EffectManager,
    scopes: ScopeManager,
    services: ServiceContainer,
};
```

Context 是整个 Cordis Native 的：

> **Kernel Object**

---

# 五、Service Container

TypeScript 可以通过动态属性：

```ts
ctx.database
ctx.http
ctx.console
```

Zig 必须设计类型安全的 Service Registry。

推荐：

```zig
pub const ServiceId = enum(u32) {
    logger,
    database,
    http,
    timer,
    config,
};
```

但不能只用 enum。

插件生态需要动态注册，所以建议：

```zig
pub const ServiceKey = struct {
    namespace: []const u8,
    name: []const u8,
    version: u32,
};
```

Registry：

```zig
pub const ServiceRegistry = struct {
    services: HashMap(ServiceKey, ServiceEntry),
};
```

ServiceEntry：

```zig
pub const ServiceEntry = struct {
    ptr: *anyopaque,
    vtable: *const ServiceVTable,
    lifecycle: Lifecycle,
};
```

这样可以获得：

```text
动态插件
+
静态内存
+
ABI-like interface
```

---

# 六、Plugin 是最重要的

Cordis 的 Plugin 思想不能简单理解成：

```text
plugin = function
```

而应该：

```text
Plugin
  ↓
declare dependency
  ↓
create scope
  ↓
register service
  ↓
register event
  ↓
register effect
  ↓
cleanup
```

Zig：

```zig
pub const Plugin = struct {
    name: []const u8,

    dependencies: []const Dependency,

    init: *const fn (*Context) anyerror!void,

    dispose: ?*const fn (*Context) void,
};
```

但是这里还不够。

我建议使用：

```zig
pub const PluginVTable = struct {
    init: *const fn (
        ctx: *Context,
    ) anyerror!void,

    dispose: *const fn (
        ctx: *Context,
    ) void,
};
```

最终：

```zig
pub const Plugin = struct {
    id: PluginId,
    vtable: PluginVTable,
    dependencies: []Dependency,
};
```

---

# 七、Scope 是 Cordis 的灵魂之一

Scope 不能简单实现成：

```text
Context child
```

它应该承担：

```text
Scope
 ├── parent
 ├── children
 ├── services
 ├── effects
 ├── events
 └── disposal
```

结构：

```zig
pub const Scope = struct {
    id: ScopeId,

    parent: ?*Scope,

    state: ScopeState,

    services: ServiceRegistry,

    effects: EffectRegistry,

    children: ScopeList,
};
```

生命周期：

```text
CREATED
   ↓
ACTIVE
   ↓
DISPOSING
   ↓
DISPOSED
```

---

# 八、为什么 Zig 反而可以把 Scope 做得更漂亮

TypeScript：

```text
GC
 ↓
object references
 ↓
event listeners
 ↓
manual dispose
```

容易产生：

> listener 泄漏 / timer 泄漏 / plugin 生命周期错乱。

Zig 可以直接：

```zig
scope.deinit();
```

然后递归：

```text
Scope.deinit
   │
   ├── dispose children
   ├── dispose effects
   ├── unregister events
   ├── dispose services
   └── free memory
```

这会让 Cordis 的生命周期模型更加确定。

---

# 九、Event System

Cordis 的 Event 是另外一个核心。

不要实现成简单：

```zig
ArrayList(Function)
```

而应该：

```text
EventBus
  │
  ├── EventType Registry
  │
  ├── Listener Registry
  │
  ├── Priority
  │
  ├── Scope
  │
  └── Dispatcher
```

例如：

```zig
pub const Event = struct {
    type_id: EventTypeId,
    source: ?ServiceId,
    payload: *const anyopaque,
};
```

Listener：

```zig
pub const Listener = struct {
    scope: *Scope,

    priority: i32,

    callback: *const fn (
        *Context,
        *const Event,
    ) anyerror!void,
};
```

---

# 十、Event 必须支持生命周期绑定

这是 Zig 版最值得优化的地方。

例如：

```text
plugin A
   │
   └── subscribe(event X)

scope destroyed
   │
   └── automatically unsubscribe
```

而不是：

```text
event X
 ↓
callback
 ↓
plugin already destroyed
 ↓
crash
```

所以 Listener 必须拥有：

```zig
scope: *Scope
```

Dispatcher 执行前：

```zig
if (listener.scope.isAlive()) {
    listener.callback(...);
}
```

这样可以实现：

> **Scope-aware Event System**

---

# 十一、Effect System

这是 Cordis 和普通 Event Framework 最大的区别之一。

Effect 可以理解为：

> **一个可被追踪、组合、等待、取消、清理的副作用。**

建议：

```zig
pub const Effect = struct {
    id: EffectId,

    scope: *Scope,

    state: EffectState,

    cancel: *const fn (*Effect) void,

    dispose: *const fn (*Effect) void,
};
```

状态：

```text
CREATED
   ↓
RUNNING
   ↓
COMPLETED
   │
   └── FAILED

or

RUNNING
   ↓
CANCELLED
```

---

# 十二、把 Effect 与 std.Io 结合

这是 Zig 0.17 重写最关键的技术点。

不要自己造一套 async runtime。

应该：

```text
Cordis
   │
   ▼
std.Io
   │
   ├── File
   ├── Network
   ├── Timer
   ├── Process
   └── Async operation
```

Zig 0.16 已经把 I/O 统一抽象到了 `std.Io`，因此 Zig 0.17 版本应该围绕 `std.Io` 设计 Runtime，而不是沿用早期 Zig 的旧 I/O 模型。

---

# 十三、Effect Scheduler

建议：

```text
              Scheduler
                  │
       ┌──────────┼──────────┐
       ▼          ▼          ▼
     Ready      Waiting    Cancelled
       │          │
       ▼          ▼
    Executor     Timer
       │
       ▼
    std.Io
```

API：

```zig
pub const Scheduler = struct {
    io: std.Io,

    pub fn spawn(
        self: *Scheduler,
        scope: *Scope,
        task: Task,
    ) !Effect;

    pub fn cancel(
        self: *Scheduler,
        effect: EffectId,
    ) void;
};
```

---

# 十四、Dependency System

Cordis 很重要的一点是：

```text
Plugin A
  ↓ requires
Service B
```

因此不能简单：

```text
plugin.init()
```

应该先建立：

```text
Dependency Graph
```

例如：

```text
Logger
  ↑
HTTP
  ↑
API
  ↑
Bot
```

然后：

```text
topological sort
```

得到：

```text
Logger
 ↓
HTTP
 ↓
API
 ↓
Bot
```

初始化顺序反过来销毁：

```text
Bot
 ↓
API
 ↓
HTTP
 ↓
Logger
```

---

# 十五、Dependency Resolver

```zig
pub const DependencyResolver = struct {

    pub fn resolve(
        plugins: []Plugin,
    ) !Resolution;
};
```

Resolution：

```zig
pub const Resolution = struct {
    initialization_order: []PluginId,
    dependency_graph: Graph,
};
```

发现：

```text
A → B
B → C
C → A
```

直接返回：

```text
DependencyCycle
```

---

# 十六、这会形成 Cordis 的真正 Runtime

最终：

```text
                 Cordis Runtime
                       │
       ┌───────────────┼────────────────┐
       │               │                │
       ▼               ▼                ▼
 Dependency        Scope            Service
 Resolver          Manager          Registry
       │               │                │
       └───────────────┼────────────────┘
                       ▼
                  Plugin System
                       │
             ┌─────────┴─────────┐
             ▼                   ▼
         Event Bus          Effect System
             │                   │
             └─────────┬─────────┘
                       ▼
                    std.Io
```

这才是 Cordis Native。

---

# 十七、建议的源码结构

我会重新设计成：

```text
cordis-native/
│
├── build.zig
├── build.zig.zon
│
├── src/
│   │
│   ├── cordis.zig
│   │
│   ├── core/
│   │   ├── context.zig
│   │   ├── scope.zig
│   │   ├── runtime.zig
│   │   └── error.zig
│   │
│   ├── plugin/
│   │   ├── plugin.zig
│   │   ├── manager.zig
│   │   ├── resolver.zig
│   │   └── dependency.zig
│   │
│   ├── service/
│   │   ├── service.zig
│   │   ├── registry.zig
│   │   └── container.zig
│   │
│   ├── event/
│   │   ├── event.zig
│   │   ├── bus.zig
│   │   ├── listener.zig
│   │   └── dispatcher.zig
│   │
│   ├── effect/
│   │   ├── effect.zig
│   │   ├── scheduler.zig
│   │   ├── task.zig
│   │   └── cancellation.zig
│   │
│   ├── scope/
│   │   ├── scope.zig
│   │   ├── lifecycle.zig
│   │   └── cleanup.zig
│   │
│   ├── io/
│   │   ├── io.zig
│   │   ├── timer.zig
│   │   ├── process.zig
│   │   └── network.zig
│   │
│   ├── loader/
│   │   ├── loader.zig
│   │   ├── manifest.zig
│   │   └── module.zig
│   │
│   └── abi/
│       ├── c.zig
│       └── wasm.zig
│
├── tests/
│
├── examples/
│
└── docs/
```

---

# 十八、Plugin ABI 是关键设计

这里我要特别强调：

**不要把 Zig Plugin 设计成编译期静态 import。**

否则失去 Cordis 最大价值。

应该支持三种 Plugin：

```text
                    Plugin
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
     Native          C ABI        WASM
      Zig             │             │
                      ▼             ▼
                   Rust/C        Sandboxed
```

第一阶段先：

```text
Zig Plugin
```

第二阶段：

```text
C ABI Plugin
```

第三阶段：

```text
WASM Plugin
```

---

# 十九、WASM Plugin 特别适合 Cordis

因为 Cordis 本质上是：

> **可组合 Plugin Runtime**

WASM 可以成为跨语言插件格式：

```text
Cordis Native
      │
      ▼
WASM Runtime
      │
 ┌────┼────┐
 ▼    ▼    ▼
Rust Go  TypeScript
```

这样未来：

```text
Cordis Plugin Marketplace
```

完全有可能成立。

> 实现细节（已实现的 opcode 子集、f64 / bulk-memory 支持、sandbox 不变式）见
> [`docs/wasm-interpreter.md`](docs/wasm-interpreter.md)。

---

# 二十、TypeScript → Zig 映射

可以这样对应：

| TypeScript Cordis | Zig Native                  |
| ----------------- | --------------------------- |
| Context           | `Context`                   |
| Scope             | `Scope`                     |
| Plugin            | `Plugin + VTable`           |
| Service           | `Service + Registry`        |
| Event             | `Event`                     |
| Event Listener    | `Listener`                  |
| Effect            | `Effect`                    |
| Lifecycle         | `Lifecycle`                 |
| Dependency        | `Dependency Graph`          |
| Promise           | `Effect/Future`             |
| async/await       | `std.Io`                    |
| EventEmitter      | `EventBus`                  |
| dynamic object    | `Registry/HashMap`          |
| closure           | function pointer + userdata |
| GC                | explicit allocator          |
| module            | Plugin                      |
| npm package       | Cordis Plugin Package       |

---

# 二十一、最重要的：不要追求 API 兼容

例如 TypeScript：

```ts
ctx.on('message', callback)
```

Zig 不需要强行：

```zig
ctx.on("message", callback);
```

我更建议：

```zig
ctx.events.subscribe(
    MessageEvent,
    handler,
);
```

或者：

```zig
ctx.on(MessageEvent, handler);
```

原因是 Zig 最大优势就是：

> **Compile-time type safety**

应该把 TypeScript 的：

```text
string event name
dynamic payload
```

升级成：

```text
EventType(T)
```

---

# 二十二、Typed Event

例如：

```zig
pub const MessageEvent = struct {
    user_id: []const u8,
    content: []const u8,
};
```

注册：

```zig
ctx.on(
    MessageEvent,
    onMessage,
);
```

handler：

```zig
fn onMessage(
    ctx: *Context,
    event: *const MessageEvent,
) !void {
    // ...
}
```

这样：

```text
Event Name
      ↓
Compile-time Type
```

这是 Zig 重写后比 TypeScript 版本更强的地方。

---

# 二十三、Memory Ownership

Cordis Native 最容易踩坑的是：

```text
Scope
 ↓
Event
 ↓
Payload
 ↓
Plugin
```

谁负责释放？

我的建议是明确三层 allocator：

```text
Global Allocator
       │
       ▼
Context Allocator
       │
       ▼
Scope Arena
       │
       ▼
Event temporary
```

生命周期：

```text
Context
 └── Scope
      ├── Plugin
      ├── Service
      └── temporary objects
```

Scope 销毁：

```text
scope.deinit()
```

直接释放整个 Scope Arena。

---

# 二十四、不要让 Event Payload 到处复制

高性能版本：

```zig
pub const EventPayload = union(enum) {
    inline: []const u8,
    owned: []u8,
    ptr: *const anyopaque,
};
```

对于高频 Event：

```text
zero-copy
```

对于跨线程：

```text
owned
```

对于 ABI：

```text
serialized
```

---

# 二十五、运行模式

最终可以提供三个模式：

### Embedded

```text
Application
   ↓
libcordis
```

### Daemon

```text
cordisd
   ↓
HTTP / IPC / MCP
```

### Plugin Host

```text
cordisd
   ↓
WASM / C ABI Plugins
```

这三个模式会非常有价值。

---

# 二十六、与 OpenClaw / Hermes 的结合

这次纠正之后，反而发现 **Cordis 和你前面研究的 Agent Runtime 是可以很好结合的**，但关系完全不同。

不是：

```text
OpenClaw
 ↓
Cordis Memory
```

而是：

```text
                 Agent
                   │
             OpenClaw/Hermes
                   │
                   ▼
             ┌────────────┐
             │   Cordis   │
             │ Native     │
             └─────┬──────┘
                   │
       ┌───────────┼───────────┐
       ▼           ▼           ▼
    Plugin       Event       Effect
       │           │           │
       ▼           ▼           ▼
     Tool        State       Async IO
```

**Cordis = Agent Plugin/Runtime Composition Layer**

而不是 Agent Memory。

---

# 二十七、进一步可以做成 Agent Kernel

这就是我认为这次重写最有价值的方向。

Cordis 原本是：

```text
Spatiotemporal Composability
```

Zig 版本可以进一步变成：

```text
                CORDIS
                  │
        ┌─────────┼─────────┐
        ▼         ▼         ▼
      SPACE      TIME     EFFECT
        │         │         │
        ▼         ▼         ▼
      Scope    Lifecycle   Async
        │         │         │
        └─────────┼─────────┘
                  ▼
             Composition
                  │
                  ▼
               Plugin
```

也就是：

> **Space = Scope**

> **Time = Lifecycle**

> **Causality = Event**

> **Effect = Side Effect**

> **Composition = Plugin**

这才是 Cordis 这个项目真正有意思的理论内核。

---

# 二十八、建议的重写路线

不要一次性重写全部 packages。

### Phase 0 — Reverse Engineering

先把 TypeScript Cordis 的源码拆成：

```text
Core Semantics
API Surface
Lifecycle
Dependency
Event
Effect
Plugin
Loader
Worker
CLI
```

建立：

```text
TS behavior test suite
```

作为 Zig 的 oracle。

---

### Phase 1 — Kernel

只实现：

```text
Context
Scope
Lifecycle
Service
Plugin
```

目标：

```text
Plugin
 ↓
Context
 ↓
Service
 ↓
Scope
 ↓
Dispose
```

---

### Phase 2 — Event

实现：

```text
Event
Listener
Priority
Scope Binding
Dispatch
Once
Dispose
```

---

### Phase 3 — Effect

实现：

```text
Effect
Scheduler
Cancellation
Timer
std.Io
```

---

### Phase 4 — Dependency

实现：

```text
Dependency Graph
Resolver
Topological Sort
Cycle Detection
Lifecycle Ordering
```

---

### Phase 5 — Loader

再做：

```text
Native Plugin
C ABI
WASM
```

---

### Phase 6 — Compatibility

最终：

```text
Cordis TS
      │
      │ same semantic tests
      ▼
Cordis Zig
```

---

# 二十九、最终架构

我会把最终版本定成：

```text
                    ┌─────────────────────┐
                    │     Application     │
                    └──────────┬──────────┘
                               │
                         Cordis API
                               │
                    ┌──────────▼──────────┐
                    │    Cordis Kernel    │
                    │       Zig 0.17      │
                    └──────────┬──────────┘
                               │
       ┌───────────────────────┼───────────────────────┐
       │                       │                       │
       ▼                       ▼                       ▼
 Dependency                Context                  Runtime
   Graph                      │                       │
       │                ┌─────┼─────┐                 │
       │                ▼     ▼     ▼                 ▼
       │             Scope Service Event          Scheduler
       │                │       │     │                │
       └────────────────┼───────┼─────┼────────────────┘
                        │       │     │
                        ▼       ▼     ▼
                     Plugin   Effect  EventBus
                        │       │     │
                        └───────┼─────┘
                                ▼
                             std.Io
                                │
             ┌──────────────────┼──────────────────┐
             ▼                  ▼                  ▼
          Native              C ABI              WASM
          Plugin              Plugin             Plugin
```

## 最终判断

这次重新看源码后，我的结论反而更明确：

**Cordis 非常适合用 Zig 0.17 重写。**

但重写目标应该是：

> **TypeScript Meta-Framework → Zig Native Composable Runtime**

而不是我上一条错误理解的：

> Agent Cognitive Engine。

而且我认为最值得做的不是单纯追求性能，而是利用 Zig 把 Cordis 的几个核心概念**类型化、确定化、原生化**：

```text
TypeScript Cordis
    ↓
Dynamic Composition
    ↓
Zig Cordis
    ↓
Typed Composition
    +
Deterministic Lifecycle
    +
Native Async I/O
    +
Zero/Low-copy Event
    +
WASM Plugin
    +
C ABI
```

这会使它从一个 **Node.js Plugin Framework**，升级成一个可以嵌入 **AI Agent、Bot、游戏、机器人、边缘节点、服务器、WASM 应用** 的通用 **Composable Runtime Kernel**。

尤其值得注意的是，官方仓库现在已经明确把 Cordis 描述为 *Spatiotemporal Composability*，并附有相关论文；因此如果认真重写，**应该围绕“时空可组合性”的语义做形式化设计，而不是围绕现有 TypeScript API 做机械翻译。** ([GitHub][1])

[Cordis 原始仓库](https://github.com/cordiverse/cordis?utm_source=chatgpt.com)

[1]: https://github.com/cordiverse/cordis "GitHub - cordiverse/cordis: Meta-Framework of Spatiotemporal Composability · GitHub"
[2]: https://www.npmjs.com/package/cordis?utm_source=chatgpt.com "cordis - npm"
