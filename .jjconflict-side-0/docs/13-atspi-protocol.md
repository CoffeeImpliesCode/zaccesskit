Consumed by `docs/30-port-design.md`, which turns the gaps in §6 into binding
design decisions, and by `docs/40-plan.md` and `docs/50-verification.md`.

# 13 — AT-SPI over D-Bus: the contract AccessKit must satisfy

## 0. Scope, sources, and what could not be reached

AccessKit's Linux accessibility bridge is two crates:

| Crate | Path in the pinned tree | Version | Role |
|---|---|---|---|
| `accesskit_atspi_common` | `/tmp/scratch/accesskit/adapters/atspi-common` | 0.21.0 (`adapters/atspi-common/Cargo.toml:3`) | Pure translation layer. Tree diffing, role and state mapping, and every "what does this node expose" decision. It opens no connection, exports no object, and emits no signal. It does derive zvariant `Type` for the two wire shapes it owns, `Rect` (`atspi-common/src/rect.rs:11-16`) and `Action` (`atspi-common/src/action.rs:7-13`). |
| `accesskit_unix` | `/tmp/scratch/accesskit/adapters/unix` | 0.24.0 (`adapters/unix/Cargo.toml:3`) | The D-Bus server. Exports the interfaces, emits the signals, owns the bus connection. |

Tree pinned at commit `466e24e252103f4d82bd6fbab98141b551e46e0c`. Line
numbers below are from that tree. `wc -l` over `adapters/atspi-common/src/*.rs`
gives 4417 lines in total, across 13 files. `adapters/unix/src/*.rs` is the
next crate and gives 809; inside it, `adapters/unix/src/atspi/` holds 662 lines
in `bus.rs`, `mod.rs`, `object_address.rs` and `object_id.rs`, and
`atspi/interfaces/*.rs` holds 1289.

> **Corrected 2026-10-05.** This paragraph read "5226 lines in total" for
> `adapters/atspi-common/src/*.rs`. 5226 is 4417 plus the 809 lines of the next
> crate, so the figure measured two directories and named one. The measurements
> above are `wc -l` over each group. §11.1 row K7 holds the arithmetic.

The D-Bus interface definitions come from the AT-SPI2 reference
implementation, fetched over HTTPS from `gitlab.gnome.org`, default branch
`main`:

```
xml/Accessible.xml xml/Action.xml xml/Application.xml xml/Cache.xml
xml/Component.xml xml/Document.xml xml/EditableText.xml xml/Event.xml
xml/Hyperlink.xml xml/Image.xml xml/Selection.xml xml/Socket.xml
xml/Text.xml xml/Value.xml
```

Each fetched through
`https://gitlab.gnome.org/api/v4/projects/GNOME%2Fat-spi2-core/repository/files/xml%2F<name>/raw?ref=main`.
The default branch is `main`, not `master`; `?ref=master` returns
`{"message":"404 Commit Not Found"}`.

Two more primary sources from the same project:

- `registryd/paths.h` — the well-known names and paths. `SPI_DBUS_PATH_CACHE`
  is `"/org/a11y/atspi/cache"`, `SPI_DBUS_PATH_ROOT` is
  `"/org/a11y/atspi/accessible/root"`, `SPI_DBUS_PATH_NULL` is
  `"/org/a11y/atspi/null"`, `SPI_DBUS_NAME_REGISTRY` is
  `"org.a11y.atspi.Registry"`.
- `bus/accessibility.conf.in` and `bus/at-spi-bus-launcher.c` — how the
  accessibility bus is started and how its address is built.

**Not reached.** The `org.a11y.Bus` and `org.a11y.Status` interfaces live in
the separate `at-spi2-registryd` project. That project returns
`404 Project Not Found` on `gitlab.gnome.org` and `404` on
`api.github.com/repos/GNOME/at-spi2-registryd`. For those two interfaces this
document relies on the generated proxy in the `atspi-proxies` crate, which is
the code AccessKit actually calls, and says so at each use.

### Property naming

zbus derives a property's D-Bus name from the Rust function name by
converting it to PascalCase: `zbus_macros-5.19.0/src/iface.rs:256-264` calls
`pascal_case(&name)`, defined at `zbus_macros-5.19.0/src/utils.rs:48-61`.
So `fn n_actions` becomes `NActions`, `fn child_count` becomes `ChildCount`,
and `fn set_current_value` becomes the setter of `CurrentValue`
(`iface.rs:258-262` strips the `set_` prefix first). The names in the table
below are the wire names, which is what matters.

## 1. The Rust D-Bus dependency

| Crate | Declared | Resolved | What it is |
|---|---|---|---|
| `zbus` | `5.19`, `default-features = false`, `features = ["async-io"]` (`adapters/unix/Cargo.toml:25`) | `5.19.0` (`Cargo.lock:2960`) | The pure-Rust D-Bus implementation. Connections, message serialisation, the object server, property dispatch, signal emission. |
| `zbus_macros` | transitive | `5.19.0` (`Cargo.lock:3019`) | `#[interface]` and `#[proxy]` attribute macros. |
| `zbus_names` | transitive | `4.3.4` (`Cargo.lock:3034`) | Validated `UniqueName`, `InterfaceName`, `MemberName`. |
| `zvariant` | `5.15`, `default-features = false` (`adapters/atspi-common/Cargo.toml:23`) | `5.15.0` (`Cargo.lock:3086`) | The GVariant type system. `#[derive(Type)]` writes the signature. |
| `atspi` | `0.29`, `default-features = false`, `features = ["proxies"]` (`adapters/unix/Cargo.toml:22`) | `0.29.0` (`Cargo.lock:352`) | Umbrella crate. Re-exports `atspi_common` and `atspi_proxies` (`atspi-0.29.0/src/lib.rs:18-22`). |
| `atspi-common` | `0.13`, `default-features = false` (`adapters/atspi-common/Cargo.toml:20`) | `0.13.0` (`Cargo.lock:362`) | Wire types: `Interface`, `InterfaceSet`, `Role`, `State`, `StateSet`, `RelationType`, `CoordType`, `Granularity`, `ScrollType`, `Layer`, `ObjectRef`. |
| `atspi-proxies` | transitive via the `proxies` feature | `0.13.0` | Client proxies. AccessKit uses `bus::BusProxy`, `bus::StatusProxy`, `socket::SocketProxy`. |
| `serde` | `1.0` | `1.0.228` (`Cargo.lock:1824`) | Serde derives on wire types. |
| `phf` | `0.14`, features `["macros"]` (`adapters/atspi-common/Cargo.toml:21`) | `0.14.0` (`Cargo.lock:1458`) | A compile-time map for the text-attribute getters (`atspi-common/src/text_attributes.rs:8`). |

Async runtime, chosen by feature flag (`adapters/unix/Cargo.toml:14-17`):

- `async-io` (default): `async-channel`, `async-executor`, `async-task`,
  `futures-util`. `futures-lite` for `block_on`
  (`adapters/unix/src/util.rs:13-15`).
- `tokio`: `tokio` with `macros, net, rt, sync, time` plus `tokio-stream`.

### What exists only because of zbus

| Construct | Exists because of | Source |
|---|---|---|
| `#[interface(name = "…")]` on 12 impl blocks | zbus generates the dispatch table and the introspection XML from the impl block | `atspi/interfaces/*.rs`, each `#[interface(...)]` line |
| `#[zbus(property)]` on 24 accessors | zbus turns a getter into `org.freedesktop.DBus.Properties.Get`, `GetAll`, and `Set` | `accessible.rs:35`, `action.rs:23`, `application.rs:15`, and 21 more |
| `#[zbus(name = "GetURI")]` | The Rust name `get_uri` would otherwise serialise as `GetUri` | `atspi/interfaces/hyperlink.rs:55-56` |
| `EventBodyBorrowed` | The fixed five-field event body `siiva{sv}` | `atspi-common-0.13.0/src/events/event_body.rs:188-210`. That crate is not on this host, so the field names and defaults are **unverified here**; see §11.3 row U1 |
| `OwnedObjectAddress` | The `(so)` object reference. Its `null()` form uses `NULL_PATH` | `atspi/object_address.rs:17-19, 29-35` |
| `map_or_ignoring_recoverable_error` | zbus returns `InterfaceExists` when the same interface is registered twice; AccessKit must swallow that | `atspi/bus.rs:512-525` |
| `zbus_error_is_unrecoverable` | Classifies `InterfaceExists` and `MissingParameter` as fatal, everything else as recoverable | `atspi/bus.rs:505-510` |
| `ObjectId` | Maps `(adapter_id, FullNodeId)` onto a path and onto the `"root"` / decimal-string wire form | `atspi/object_id.rs:22-78` |
| `phf` map | A compile-time `&str -> getter` table for `Text.GetAttributes`. A plain match would need a runtime map | `atspi-common/src/text_attributes.rs:8, 68-79` |

Two files in `atspi-common/src/` are not D-Bus at all:
`simplified.rs` (977 lines, behind the `simplified-api` feature) is a
platform-API facade, and `filters.rs` is a single re-export of
`accesskit_consumer::common_filter` (`filters.rs:6`).

## 2. Bus and connection

There are two buses. The session bus is used once, to find the other one.

### Threading model

All bus work happens on **one dedicated OS thread**, started once, guarded by a
`OnceLock`:

```
adapters/unix/src/context.rs:33-34   static APP_CONTEXT: OnceLock<...>
                                     static MESSAGES: OnceLock<Sender<Message>>
adapters/unix/src/context.rs:47      pub(crate) fn get_or_init_messages() -> Sender<Message>
adapters/unix/src/context.rs:55          thread::spawn(|| {
adapters/unix/src/context.rs:56              let executor = Executor::new();
adapters/unix/src/context.rs:57              block_on(executor.run(async {
adapters/unix/src/context.rs:58                  if let Ok(session_bus) = Builder::session() {
```

The main thread never touches zbus. It pushes `Message` values into an
unbounded channel (`async_channel::unbounded()` at `context.rs:51`, or
`tokio::sync::mpsc::unbounded_channel()` under the tokio feature). The doc
comment at `adapters/unix/src/adapter.rs:132` states the contract: "All of the
handlers will always be called from another thread."

### Step 1: the session bus

```
adapters/unix/src/context.rs:58   Builder::session()
adapters/unix/src/context.rs:59       .internal_executor(false).build().await
adapters/unix/src/context.rs:178  session_bus_copy.executor().tick().await   (loop)
```

`.internal_executor(false)` stops zbus from starting its own executor, so the
outer `Executor` drives the connection instead. `context.rs:175-182` spawns a
task named `"accesskit_session_bus_task"` whose only job is to `tick()` that
connection forever.

### Step 2: watch accessibility on or off

```
adapters/unix/src/context.rs:184   let status = StatusProxy::new(&session_bus).await?;
adapters/unix/src/context.rs:185   let changes = status.receive_is_enabled_changed().await.fuse();
```

`StatusProxy` is generated in `atspi-proxies-0.13.0/src/bus.rs:22-38` as
interface `org.a11y.Status`, default service `org.a11y.Bus`, default path
`/org/a11y/bus`, with two read/write properties `IsEnabled` (`b`) and
`ScreenReaderEnabled` (`b`). AccessKit only watches `IsEnabled`.

The changes stream and the message channel are then selected against each
other in one loop:

```
adapters/unix/src/context.rs:197  loop {
adapters/unix/src/context.rs:198      select! {
adapters/unix/src/context.rs:199          change = changes.next() => { … }
adapters/unix/src/context.rs:204          message = messages.next() => { … }
```

`bus_after_status_change` (`context.rs:142-152`) maps the change to a bus: on
`true` it calls `Bus::new(session_bus, executor).await`; on `false` it drops
the bus. `sync_adapters` (`context.rs:154-162`) then activates or deactivates
every adapter to match.

### Step 3: the accessibility bus address

```
adapters/unix/src/atspi/bus.rs:43   let address = match var("AT_SPI_BUS_ADDRESS") {
adapters/unix/src/atspi/bus.rs:44       Ok(address) if !address.is_empty() => address,
adapters/unix/src/atspi/bus.rs:45       _ => BusProxy::new(session_bus).await?.get_address().await?,
adapters/unix/src/atspi/bus.rs:47   let address: Address = address.as_str().try_into()?;
adapters/unix/src/atspi/bus.rs:48   let conn = Builder::address(address)?
adapters/unix/src/atspi/bus.rs:49       .internal_executor(false)
adapters/unix/src/atspi/bus.rs:50       .build()
adapters/unix/src/atspi/bus.rs:51       .await?;
```

`BusProxy` is `org.a11y.Bus` on `org.a11y.Bus` at `/org/a11y/bus`, one method
`GetAddress() -> s` (`atspi-proxies-0.13.0/src/bus.rs:40-49`).

The address string is either `unix:path=<filesystem path>` or
`unix:abstract=<name>`. The launcher picks:

```
bus/at-spi-bus-launcher.c:538  if (app->socket_name)
bus/at-spi-bus-launcher.c:539      app->a11y_bus_address = g_strconcat ("unix:path=", addr.sun_path, NULL);
bus/at-spi-bus-launcher.c:540  else
bus/at-spi-bus-launcher.c:541      app->a11y_bus_address = g_strconcat ("unix:abstract=", addr.sun_path + 1, NULL);
```

This matters. The `unix:abstract=` form is not a filesystem path and only the
second branch applies when the bind address length filled `sun_path`
completely.

Then, again, a `tick()` task named `"accesskit_atspi_bus_task"` drives this
second connection (`bus.rs:52-60`).

### Authentication

There is no authentication code in AccessKit. The daemon config is what
decides:

```
bus/accessibility.conf.in:7   <auth>EXTERNAL</auth>
bus/accessibility.conf.in:10    <allow send_destination="*"/>
bus/accessibility.conf.in:11    <allow receive_type="signal"/>
bus/accessibility.conf.in:15    <allow own="*"/>
```

`EXTERNAL` means the client proves its uid with a `SO_PEERCRED` credential on
the socket; no password, no `DBUS_COOKIE_SHA1`. The policy allows any name to
be owned and allows all signals to be received, which is why AccessKit never
calls `AddMatch`.

### Step 4: register the application root

```
adapters/unix/src/atspi/bus.rs:61   let socket_proxy = SocketProxy::new(&conn).await?;
adapters/unix/src/atspi/bus.rs:76   async fn register_root_node(&mut self) -> Result<()> {
adapters/unix/src/atspi/bus.rs:81-84     .object_server().at(path, ApplicationInterface(node))
adapters/unix/src/atspi/bus.rs:86-89     .embed(&(self.unique_name().as_str(), ObjectId::Root.path().into()))
adapters/unix/src/atspi/bus.rs:92-102    .object_server().at(path, RootAccessibleInterface::new(…))
adapters/unix/src/atspi/bus.rs:104-113   .object_server().at(cache_path(), CacheInterface::new(…))
```

`SocketProxy` is `org.a11y.atspi.Socket` on `org.a11y.atspi.Registry` at
`/org/a11y/atspi/accessible/root` (`atspi-proxies-0.13.0/src/socket.rs:14-20`).
`Embed(plug: (so)) -> (so)` registers the application and returns the
registry's desktop root reference, which `bus.rs:90` stores in a `OnceLock`
and reuses as the root object's parent (`accessible.rs:179-186`).

The whole block runs only if registering `ApplicationInterface` returned true,
that is, only once per process (`bus.rs:76-118`).

Two facts in this block decide whether the port can work at all, and neither is
a protocol detail. Neither was in this document before 2026-10-05. Both are
recorded with their evidence in §11.2.

**B1. goose never learns its own unique name.** `self.unique_name()`
(`bus.rs:72-73`) is the caller's own unique bus name, and it is the plug half of
the `Embed` argument at `bus.rs:88`. goose does not have it: `sayHello`
(`connection.zig:549`) receives the `Hello` reply, binds it to a local at `:572`
and frees it at `:573`. There is no field and no accessor for it anywhere in
the goose tree; `grep -rn "unique" src/` returns one hit, a doc comment at
`proxy.zig:52`. A D-Bus client that cannot name itself cannot register, so
**the port cannot register at all** until goose keeps that reply.

**B2. `Embed` with a foreign plug name kills `at-spi2-registryd`.** The plug
must be the caller's own unique name. `Embed` called with any other plug name
aborts the registry process on this bus; the launcher then restarts it.
Reproduced twice, with `Introspect` on the same path as the control that leaves
it running. Any harness that substitutes a literal unique name destroys the
accessibility registry on the developer's machine, so such a test must be
refused rather than written.

### Object paths

All three are string constants in `atspi/object_id.rs:14-16`:

| Path | Source |
|---|---|
| `/org/a11y/atspi/accessible/root` | `object_id.rs:15` `ROOT_PATH` |
| `/org/a11y/atspi/accessible/{adapter}/{node}` | `object_id.rs:37-41`, prefix from `object_id.rs:14` |
| `/org/a11y/atspi/cache` | `object_id.rs:16` `CACHE_PATH` |

`node` is `u128::from(*node)` on a `FullNodeId`, so it is a decimal string
(`object_id.rs:40`). `adapter` is the `usize` from `next_adapter_id()`
(`atspi-common/src/adapter.rs:352-358`), which keeps window roots from
different windows at different paths. The matching null path
`/org/a11y/atspi/null` is used for absent children
(`atspi/object_address.rs:17`, `:29-35`).

AccessKit owns **no well-known name** on the accessibility bus. It uses the
connection's unique name (`bus.rs:70-72`) and reaches the registry only
through `Embed`.

## 3. Interfaces, objects and paths

This is the contract. Every row is a member AccessKit touches.

Column meanings:

- **Wire name** — the member or property name on the bus, after PascalCase for
  properties (§0).
- **In / Out** — D-Bus signature. Properties show the variant payload type.
- **Source** — `path:line` in the pinned AccessKit tree.
- **Shape** — what the implementation does.

### 3.1 Client calls AccessKit makes

| Interface | Wire name | Kind | In | Out | Source | Purpose |
|---|---|---|---|---|---|---|
| `org.a11y.Bus` | `GetAddress` | method | `()` | `s` | `adapters/unix/src/atspi/bus.rs:45` | Get the accessibility bus address when `AT_SPI_BUS_ADDRESS` is unset |
| `org.a11y.Status` | `IsEnabled` | signal (as `PropertiesChanged`) | `s a{sv} as` | — | `adapters/unix/src/context.rs:185` | Turn the bus on or off |
| `org.a11y.atspi.Socket` | `Embed` | method | `(so)` | `(so)` | `adapters/unix/src/atspi/bus.rs:86-89` | Register the application root, receive the desktop reference |

`org.a11y.Bus` and `org.a11y.Status` are cited from
`atspi-proxies-0.13.0/src/bus.rs:22-49` because `at-spi2-registryd` could not be
reached (§0).

### 3.2 `org.a11y.atspi.Application` on `/org/a11y/atspi/accessible/root`

Declared at `adapters/unix/src/atspi/interfaces/application.rs:13`. Path from
`bus.rs:81-84`.

| Wire name | Kind | Type | Source | What it returns |
|---|---|---|---|---|
| `ToolkitName` | property | `s` read | `application.rs:15-18` | `tree_state.toolkit_name()`, or the process file name |
| `Version` | property | `s` read | `application.rs:20-23` | `tree_state.toolkit_version()`, empty string when absent |
| `AtspiVersion` | property | `s` read | `application.rs:25-28` | The literal `"2.1"` |
| `Id` | property | `i` read | `application.rs:30-33` | `AppContext.id`, or `-1` when the registry has not set it |
| `Id` | property setter | `i` | `application.rs:35-38` | `Properties.Set` stores the registry-assigned id |

### 3.3 `org.a11y.atspi.Accessible` on a node path

Declared twice: for nodes at `accessible.rs:33`, for the root at
`accessible.rs:166`. Registered per node at `bus.rs:127-132`.

| Wire name | Kind | Type | Source (node) | Source (root) | What it returns |
|---|---|---|---|---|---|
| `Name` | property | `s` read | `accessible.rs:35-38` | `accessible.rs:168-171` | Label, or value when the label comes from the value |
| `Description` | property | `s` read | `accessible.rs:40-43` | `accessible.rs:173-176` | `node.description()`, empty string for the root |
| `Parent` | property | `(so)` read | `accessible.rs:45-57` | `accessible.rs:178-186` | Parent object reference; the desktop reference for the root |
| `ChildCount` | property | `i` read | `accessible.rs:59-62` | `accessible.rs:188-191` | Filtered child count; adapter count for the root |
| `Locale` | property | `s` read | `accessible.rs:64-67` | `accessible.rs:193-196` | Always `""` |
| `AccessibleId` | property | `s` read | `accessible.rs:69-72` | `accessible.rs:198-201` | `node.accessible_id()`, empty string for the root |
| `GetChildAtIndex` | method | `i` -> `(so)` | `accessible.rs:74-87` | `accessible.rs:203-213` | Child reference, or `/org/a11y/atspi/null` |
| `GetChildren` | method | `()` -> `a(so)` | `accessible.rs:89-99` | `accessible.rs:215-221` | All filtered child references |
| `GetIndexInParent` | method | `()` -> `i` | `accessible.rs:101-103` | `accessible.rs:223-225` | Position among siblings; `-1` for the root |
| `GetRelationSet` | method | `()` -> `a(ua(so))` | `accessible.rs:105-119` | `accessible.rs:227-229` | Relations; always empty for the root |
| `GetRole` | method | `()` -> `u` | `accessible.rs:121-123` | `accessible.rs:231-233` | AT-SPI role enum. Root returns `AtspiRole::Application` |
| `GetLocalizedRoleName` | method | `()` -> `s` | `accessible.rs:125-127` | **not implemented** | Localized role name string |
| `GetState` | method | `()` -> `au` | `accessible.rs:129-131` | `accessible.rs:235-237` | State bit values; empty for the root |
| `GetAttributes` | method | `()` -> `a{ss}` | `accessible.rs:133-135` | **not implemented** | `placeholder-text`, `posinset`, `setsize`, `id`, braille keys |
| `GetApplication` | method | `()` -> `(so)` | `accessible.rs:137-139` | `accessible.rs:239-241` | The root object reference, always |
| `GetInterfaces` | method | `()` -> `as` | `accessible.rs:141-143` | `accessible.rs:243-245` | `InterfaceSet` serialised as interface names |

The root object exports **14** of the 16 members. It omits
`GetLocalizedRoleName` and `GetAttributes`. That asymmetry is real and must
be reproduced.

### 3.4 `org.a11y.atspi.Cache` on `/org/a11y/atspi/cache`

Declared at `interfaces/cache.rs:108`, registered at `bus.rs:104-113`.

| Wire name | Kind | Type | Source | What it returns |
|---|---|---|---|---|
| `GetItems` | method | `()` -> `a((so)(so)(so)iiassusau)` | `cache.rs:110-112` | Whole-application snapshot: the application item first, then every descendant |

The item layout, field by field, is `((so)(so)(so)iiassusau)`: `object` `(so)`,
`app` `(so)`, `parent` `(so)`, `index` `i`, `children` `i`, `ifaces` `as`,
`short_name` `s`, `role` `u`, `name` `s`, `states` `au`. The field order is
`xml/Cache.xml`'s. The Rust declaration this document used to cite,
`atspi-common-0.13.0/src/cache.rs:13-40`, is **not on this host**, so the order
taken from it is **unverified here**; see §11.3 row U2. The shape and the order
do not depend on it.

### 3.5 `org.a11y.atspi.Action` on a node path

Declared at `interfaces/action.rs:21`, registered at `bus.rs:134-137`.

| Wire name | Kind | Type | Source | What it returns |
|---|---|---|---|---|
| `NActions` | property | `i` read | `action.rs:23-26` | `1` when the node is clickable, else `0` |
| `GetDescription` | method | `i` -> `s` | `action.rs:28-30` | Always `""` |
| `GetName` | method | `i` -> `s` | `action.rs:32-34` | `"click"` for index 0, else `""` |
| `GetLocalizedName` | method | `i` -> `s` | `action.rs:36-38` | Same string as `GetName` |
| `GetKeyBinding` | method | `i` -> `s` | `action.rs:40-42` | Always `""` |
| `GetActions` | method | `()` -> `a(sss)` | `action.rs:44-46` | Localised name, description, key binding triples |
| `DoAction` | method | `i` -> `b` | `action.rs:48-50` | `true` for index 0, `false` otherwise |

`DoAction(0)` ends at `atspi-common/src/node.rs:1119-1130`, which builds
`ActionRequest { action: Action::Click, target_tree, target_node, data: None }`
and hands it to `Context::do_action` (`atspi-common/src/context.rs:76-78`).

### 3.6 `org.a11y.atspi.Component` on a node path

Declared at `interfaces/component.rs:27`, registered at `bus.rs:138-144`.

| Wire name | Kind | Type | Source | What it returns |
|---|---|---|---|---|
| `Contains` | method | `i i u` -> `b` | `component.rs:29-33` | Whether the point is inside the extents |
| `GetAccessibleAtPoint` | method | `i i u` -> `(so)` | `component.rs:35-50` | Deepest node at the point, or the null reference |
| `GetExtents` | method | `u` -> `(iiii)` | `component.rs:52-57` | `x, y, width, height`; `(-1,-1,-1,-1)` when unknown |
| `GetLayer` | method | `()` -> `u` | `component.rs:59-61` | `Layer::Window` for role `Window`, else `Layer::Widget` |
| `GrabFocus` | method | `()` -> `b` | `component.rs:63-65` | `ActionRequest { action: Action::Focus, … }`, `node.rs:1184-1192` |
| `ScrollTo` | method | `u` -> `b` | `component.rs:67-69` | `Action::ScrollIntoView`, `node.rs:1194-1203` |
| `ScrollToPoint` | method | `u i i` -> `b` | `component.rs:71-75` | `node.rs:1204-1223` |

### 3.7 `org.a11y.atspi.Document` on a node path

Declared at `interfaces/document.rs:27`, registered at `bus.rs:145-148`.
Present when the node role is `RootWebArea` or `PdfRoot`
(`atspi-common/src/node.rs:453-455`).

| Wire name | Kind | Type | Source | What it returns |
|---|---|---|---|---|
| `CurrentPageNumber` | property | `i` read | `document.rs:29-32` | Always `NotSupported` |
| `PageCount` | property | `i` read | `document.rs:34-37` | Always `NotSupported` |
| `GetAttributeValue` | method | `s` -> `s` | `document.rs:39-43` | One document attribute, case-insensitive lookup |
| `GetAttributes` | method | `()` -> `a{ss}` | `document.rs:45-47` | The document attribute map |
| `GetLocale` | method | `()` -> `s` | `document.rs:49-51` | Always `NotSupported` |
| `GetTextSelections` | method | `()` -> `a((so)i(so)ib)` | `document.rs:53-55` | Always `NotSupported` |
| `SetTextSelections` | method | `a((so)i(so)ib)` -> `b` | `document.rs:57-59` | Always `NotSupported` |

### 3.8 `org.a11y.atspi.EditableText` on a node path

Declared at `interfaces/editable_text.rs:25`, registered at `bus.rs:149-152`.
Present for text inputs with text ranges (`node.rs:457-459`).

| Wire name | Kind | Type | Source | What it returns |
|---|---|---|---|---|
| `SetTextContents` | method | `s` -> `b` | `editable_text.rs:27-31` | Replaces the text; `node.rs:1225+` |
| `InsertText` | method | `i s i` -> `b` | `editable_text.rs:33-35` | Always `NotSupported` |
| `CopyText` | method | `i i` -> `()` | `editable_text.rs:37-39` | Always `NotSupported` |
| `CutText` | method | `i i` -> `b` | `editable_text.rs:41-43` | Always `NotSupported` |
| `DeleteText` | method | `i i` -> `b` | `editable_text.rs:45-47` | Always `NotSupported` |
| `PasteText` | method | `i` -> `b` | `editable_text.rs:49-51` | Always `NotSupported` |

### 3.9 `org.a11y.atspi.Hyperlink` on a node path

Declared at `interfaces/hyperlink.rs:26`, registered at `bus.rs:153-159`.

| Wire name | Kind | Type | Source | What it returns |
|---|---|---|---|---|
| `NAnchors` | property | `i` read | `hyperlink.rs:28-31` | `1` when the node has a URL, else `0` (`node.rs:1242-1244`). The type is `i`, not `n`; see §11.1 row K3 |
| `StartIndex` | property | `i` read | `hyperlink.rs:33-36` | Anchor start offset |
| `EndIndex` | property | `i` read | `hyperlink.rs:38-41` | Anchor end offset |
| `GetObject` | method | `i` -> `(so)` | `hyperlink.rs:43-53` | Anchor object reference, or the null reference |
| `GetURI` | method | `i` -> `s` | `hyperlink.rs:55-58` | Anchor URL. **Name overridden** by `#[zbus(name = "GetURI")]` |
| `IsValid` | method | `()` -> `b` | `hyperlink.rs:60-62` | Whether the link is usable |

### 3.10 `org.a11y.atspi.Image` on a node path

Declared at `interfaces/image.rs:22`, registered at `bus.rs:160-163`.

| Wire name | Kind | Type | Source | What it returns |
|---|---|---|---|---|
| `ImageDescription` | property | `s` read | `image.rs:24-27` | The node description |
| `ImageLocale` | property | `s` read | `image.rs:29-34` | Always `NotSupported` |
| `GetImageExtents` | method | `u` -> `(iiii)` | `image.rs:36-41` | `x, y, width, height` |
| `GetImagePosition` | method | `u` -> `(ii)` | `image.rs:43-45` | `x, y` |
| `GetImageSize` | method | `()` -> `(ii)` | `image.rs:47-49` | `width, height` |

### 3.11 `org.a11y.atspi.Selection` on a node path

Declared at `interfaces/selection.rs:26`, registered at `bus.rs:164-170`.
Present for containers with selectable children (`node.rs:472-474`).

| Wire name | Kind | Type | Source | What it returns |
|---|---|---|---|---|
| `NSelectedChildren` | property | `i` read | `selection.rs:28-31` | Count of selected children |
| `GetSelectedChild` | method | `i` -> `(so)` | `selection.rs:33-43` | The nth selected child |
| `SelectChild` | method | `i` -> `b` | `selection.rs:45-49` | `node.rs:1322+` |
| `DeselectSelectedChild` | method | `i` -> `b` | `selection.rs:51-55` | `node.rs` deselect path |
| `IsChildSelected` | method | `i` -> `b` | `selection.rs:57-61` | Whether child `i` is selected |
| `SelectAll` | method | `()` -> `b` | `selection.rs:63-65` | Always `false` (`node.rs:1381-1384`) |
| `ClearSelection` | method | `()` -> `b` | `selection.rs:67-69` | Always `false`. **It never clears anything** (`node.rs:1386-1389`); see §11.1 row K4 |
| `DeselectChild` | method | `i` -> `b` | `selection.rs:71-75` | Deselect child `i` |

Every index-taking member runs `map_child_index` (`selection.rs:78-82`),
which maps a negative `i32` to `InvalidArgs` with the message
`"Index can't be negative."`. `GetChildAtIndex` in `Accessible` does the same
at `accessible.rs:76-78`.

### 3.12 `org.a11y.atspi.Text` on a node path

Declared at `interfaces/text.rs:25`, registered at `bus.rs:171-174`.

| Wire name | Kind | Type | Source | What it returns |
|---|---|---|---|---|
| `CharacterCount` | property | `i` read | `text.rs:27-30` | Number of characters in the text range |
| `CaretOffset` | property | `i` read | `text.rs:32-35` | Current caret offset |
| `GetStringAtOffset` | method | `i u` -> `(sii)` | `text.rs:37-45` | Text plus start and end offsets |
| `GetText` | method | `i i` -> `s` | `text.rs:47-51` | Substring |
| `SetCaretOffset` | method | `i` -> `b` | `text.rs:53-55` | `node.rs:1467+` |
| `GetAttributeValue` | method | `i s` -> `s` | `text.rs:57-61` | One text attribute at an offset |
| `GetAttributes` | method | `i` -> `(a{ss}ii)` | `text.rs:63-68` | Attribute map plus run boundaries |
| `GetDefaultAttributes` | method | `()` -> `a{ss}` | `text.rs:70-74` | The default attribute map |
| `GetCharacterExtents` | method | `i u` -> `(iiii)` | `text.rs:76-80` | Character bounds |
| `GetOffsetAtPoint` | method | `i i u` -> `i` | `text.rs:82-86` | Offset nearest a point |
| `GetNSelections` | method | `()` -> `i` | `text.rs:88-90` | Number of selections |
| `GetSelection` | method | `i` -> `(ii)` | `text.rs:92-94` | Start and end offset of selection `i` |
| `AddSelection` | method | `i i` -> `b` | `text.rs:96-100` | Redirects to `SetSelection(0, …)`, `node.rs:1580-1583` |
| `RemoveSelection` | method | `i` -> `b` | `text.rs:102-106` | Remove selection `i` |
| `SetSelection` | method | `i i i` -> `b` | `text.rs:108-117` | `node.rs:1610+` |
| `GetRangeExtents` | method | `i i u` -> `(iiii)` | `text.rs:119-128` | Union of the range's bounding boxes |
| `GetAttributeRun` | method | `i b` -> `(a{ss}ii)` | `text.rs:130-138` | Attribute run plus boundaries |
| `ScrollSubstringTo` | method | `i i u` -> `b` | `text.rs:140-149` | `node.rs:1695+` |
| `ScrollSubstringToPoint` | method | `i i u i i` -> `b` | `text.rs:151-163` | `node.rs:1728+` |

`AddSelection` is a redirect, not a separate implementation
(`node.rs:1581-1582`). The Zig port must do the same rather than duplicating
the body.

### 3.13 `org.a11y.atspi.Value` on a node path

Declared at `interfaces/value.rs:23`, registered at `bus.rs:175-178`.
Present when `node.current_value()` is set (`node.rs:480-482`).

| Wire name | Kind | Type | Source | What it returns |
|---|---|---|---|---|
| `MinimumValue` | property | `d` read | `value.rs:25-28` | Numeric minimum |
| `MaximumValue` | property | `d` read | `value.rs:30-33` | Numeric maximum |
| `MinimumIncrement` | property | `d` read | `value.rs:35-38` | Step |
| `CurrentValue` | property | `d` read | `value.rs:40-43` | Current value |
| `CurrentValue` | property setter | `d` | `value.rs:45-48` | `Action::SetValue`, `node.rs:1779+` |

### 3.14 Members of the standard interfaces AccessKit does not export

Every interface in `xml/*.xml` carries a `version` property of type `u`. The
AT-SPI reference implementation also exports `Accessible.HelpText` (`s`),
`Accessible.GetRoleName` (`s`), `Application.InterfaceVersion` (`u`),
`Application.GetLocale` (`u` -> `s`), `Application.GetApplicationBusAddress`
(`()` -> `s`), and the whole `Table`, `TableCell`, `Hypertext`, and `Collection`
interfaces. AccessKit exports none of these.

> **Corrected 2026-10-05.** This list also carried
> `Application.ToolkitVersion` (`s`) as an omission. It is not an omission.
> `xml/Application.xml` names the property `ToolkitVersion`, and AccessKit's
> accessor is `fn version` (`application.rs:20-23`), so §0 "Property naming"
> publishes it as `Version`. §3.2 is right and this list was wrong. A port that
> follows the XML here names a property upstream never sends. §11.1 row K1.

That is not a defect. A client must treat a missing property as absent. The
Zig port must also omit them, because a port that adds members upstream does
not have is not a port.

### 3.15 Error mapping

One function maps the internal error enum to `fdo::Error`
(`adapters/unix/src/util.rs:27-40`):

| Internal error (`atspi-common/src/error.rs:9-15`) | `fdo::Error` | Wire name |
|---|---|---|
| `Defunct`, `UnsupportedInterface` | `UnknownObject(path)` | `org.freedesktop.DBus.Error.UnknownObject` |
| `TooManyChildren` | `Failed("Too many children.")` | `org.freedesktop.DBus.Error.Failed` |
| `IndexOutOfRange` | `Failed("Index is too big.")` | `org.freedesktop.DBus.Error.Failed` |
| `TooManyCharacters` | `Failed("Too many characters.")` | `org.freedesktop.DBus.Error.Failed` |
| `UnsupportedTextGranularity` | `Failed("Unsupported text granularity.")` | `org.freedesktop.DBus.Error.Failed` |

Plus `InvalidArgs("Index can't be negative.")` for negative indices
(`accessible.rs:76-78`, `selection.rs:78-82`) and `NotSupported` from the
stub members in §3.7, §3.8, and §3.10.

### 3.16 Interface registration and removal

Interfaces are not fixed. Each node gets a set of them, computed by
`NodeWrapper::interfaces()` (`atspi-common/src/node.rs:484-514`), and the set
changes as the node changes:

```
adapters/unix/src/atspi/bus.rs:120-181    register_interfaces  (10 if-checks, one per interface)
adapters/unix/src/atspi/bus.rs:183-192    register_interface   (object_server().at)
adapters/unix/src/atspi/bus.rs:194-243    unregister_interfaces
adapters/unix/src/atspi/bus.rs:245-255    unregister_interface (object_server().remove)
```

The delta is computed on the consumer side as a symmetric difference
(`atspi-common/src/adapter.rs:307-314`):

```rust
let kept_interfaces = old_interfaces & new_interfaces;
self.adapter.unregister_interfaces(…, old_interfaces ^ kept_interfaces);
self.adapter.register_interfaces(…, new_interfaces ^ kept_interfaces);
```

Only the difference is sent over the bus. This is a real optimisation and the
Zig port must keep it: re-registering an unchanged interface on every node
update would multiply traffic without bound.

### 3.17 `Simplified` interface

AccessKit never registers it. So do not implement it.

## 4. Signals

Two signal families: the event interfaces, whose body is always
`s i i v a{sv}`, and the cache interface.

The body carries **five** arguments. `xml/Event.xml` declares `s`, `i`, `i`, `v`,
`a{sv}` on every signal of `org.a11y.atspi.Event.Object`,
`org.a11y.atspi.Event.Window` and `org.a11y.atspi.Event.Document`, with no
exception anywhere in the file. Measured on this host on 2026-10-05 by parsing
that XML: every `<signal>` in all seven event interfaces joins to `siiva{sv}`,
and `org.a11y.atspi.Event.Object` holds 22 of them. The five arguments are
`kind` (`s`), `detail1` (`i`), `detail2` (`i`), `any_data` (`v`) and
`properties` (`a{sv}`).

`properties` is argument five and it is **on the wire**. The file's own header
comment says the dictionary "should be empty" and is "reserved for future use";
that is a rule about its contents, not about its absence. AccessKit sends it
empty.

The upstream Rust type that builds this body is `EventBodyBorrowed`
(`atspi-common-0.13.0/src/events/event_body.rs:188-210`). That crate is not on
this host, so its field names and its defaults are **unverified here**; see
§11.3 row U1. What is not in doubt is the wire shape, which the XML settles.
Every emission still starts from `EventBodyBorrowed::default()` and overwrites
fields, so the unused arguments read `""`, `0`, `0` and a `u32` variant, and
the fifth is an empty dictionary.

`docs/26` section 4 records this same signal as `siivso`, four arguments. That
is not another spelling of this shape, it is a different shape: a client that
receives `siiva{sv}` cannot decode `siivso`, and one that receives `siivso`
cannot decode what this adapter sends. Five arguments is the requirement.
§11.1 row K2.

All signals go out with `destination = None`, that is, broadcast
(`bus.rs:470`, `bus.rs:492`).

### 4.1 `org.a11y.atspi.Event.Object`

Interface string at `bus.rs:269`. Member name mapping at `bus.rs:270-280`.
Emitted from `bus.rs:256-395`.

| Member | `kind` | `detail1` | `detail2` | `any_data` | Emitting code | Node it targets |
|---|---|---|---|---|---|---|
| `ActiveDescendantChanged` | `""` | 0 | 0 | `(so)` child reference | `bus.rs:282-291` | The window root, when it activates |
| `Announcement` | `""` | politeness as `i32` | 0 | message `s` | `bus.rs:292-297` | The node whose live region fired |
| `BoundsChanged` | `""` | 0 | 0 | `(iiii)` extents | `bus.rs:298-302` | The node whose bounds or transform moved |
| `ChildrenChanged` (add) | `"add"` | index | 0 | `(so)` child reference | `bus.rs:308-317` | The parent |
| `ChildrenChanged` (remove) | `"remove"` | `-1` | 0 | `(so)` child reference | `bus.rs:318-329` | The parent |
| `PropertyChange` | `"accessible-name"` / `"accessible-description"` / `"accessible-parent"` / `"accessible-role"` / `"accessible-value"` | 0 | 0 | `s`, `s`, `(so)`, `u`, `d` | `bus.rs:330-356` | The node whose property changed |
| `SelectionChanged` | `""` | 0 | 0 | `u32` zero (default) | `bus.rs:357-360` | The selection container |
| `StateChanged` | `state.to_static_str()`, e.g. `"active"`, `"focused"`, `"checked"` | `1` or `0` | 0 | `u32` zero (default) | `bus.rs:361-366` | The node whose state changed |
| `TextCaretMoved` | `""` | offset | 0 | `u32` zero (default) | `bus.rs:303-307` | The text node |
| `TextChanged` (insert) | `"insert"` | start index | length | content `s` | `bus.rs:367-378` | The text node |
| `TextChanged` (delete) | `"delete"` | start index | length | content `s` | `bus.rs:379-390` | The text node |
| `TextSelectionChanged` | `""` | 0 | 0 | `u32` zero (default) | `bus.rs:391-394` | The text node |

Note the internal name to wire name renaming: the Rust enum variant
`ObjectEvent::CaretMoved` becomes the member `TextCaretMoved`
(`bus.rs:274`), and `ObjectEvent::PropertyChanged` becomes `PropertyChange`
(`bus.rs:276`). `State::to_static_str` is at
`atspi-common-0.13.0/src/state.rs:231-282`, which is **not on this host**, so
the ten AT-SPI state strings it must produce are **unverified here**; see §11.3
row U3. `StateChanged` needs them, so this is a port-blocking measurement to
take, not a footnote.

### 4.2 `org.a11y.atspi.Event.Window`

Interface string at `bus.rs:415`. Member mapping at `bus.rs:409-412`.
Body: `kind` `""`, `detail1` 0, `detail2` 0, `any_data` = the window name as
`s` (`bus.rs:413-414`).

| Member | Emitting code | Node it targets |
|---|---|---|
| `Activate` | `bus.rs:398-417` | The window root node |
| `Deactivate` | `bus.rs:398-417` | The window root node |

### 4.3 `org.a11y.atspi.Event.Document`

Interface string at `bus.rs:434`. Member at `bus.rs:429-431`.

| Member | Emitting code | Node it targets |
|---|---|---|
| `LoadComplete` | `bus.rs:419-439` | A `Document` node that went from busy to not busy (`atspi-common/src/node.rs:686-690`) |

### 4.4 `org.a11y.atspi.Cache`

Interface string at `bus.rs:472`. Always emitted on `cache_path()`
(`bus.rs:471`), never on a node path.

| Member | Body | Emitting code | What it carries |
|---|---|---|---|
| `AddAccessible` | `((so)(so)(so)iiassusau)` | `bus.rs:441-446` | A whole `CacheItem` built at `cache.rs:31-58` |
| `RemoveAccessible` | `(so)` | `bus.rs:448-461` | The object reference of the removed node |

Two further members of `org.a11y.atspi.Cache` exist in `xml/Cache.xml` and
AccessKit exports neither: a `Ready` signal, added in Cache version 2, and a
`version` property of type `u`. `Ready` is the consequential one. A client that
waits for `org.a11y.atspi.Cache.Ready` before calling `GetItems` waits forever
against this adapter, because the adapter never emits it; a client that calls
`GetItems` directly, which is what a reference client does once it holds the
root path, is unaffected. §11.1 row K6.

The item builder is `cache_item` at `cache.rs:31-58`, which fills
`short_name` from `node.name` and `name` from `node.description`. That
inversion is deliberate and easy to get wrong.

### 4.5 Signals AccessKit subscribes to

Exactly one, and it is not on the accessibility bus:

| Interface | Member | Where subscribed | What it drives |
|---|---|---|---|
| `org.a11y.Status` | `IsEnabled` changed, through `PropertiesChanged` | `adapters/unix/src/context.rs:184-185` | Creating or dropping the `Bus`, then activating or deactivating every adapter |

`xml/Socket.xml` declares `Embedded` and `Unembed`, and AccessKit exports
neither. The reason is not that they are signals it chose not to subscribe to.
**They are methods on `org.a11y.atspi.Socket`,** and the socket calls them on
the plug, so only a plug could implement them. AccessKit is the plug, and
`adapters/unix/src/atspi/interfaces/` contains no `Socket` module at all: the
adapter's whole client-side use of that interface is the one outbound `Embed`
at `bus.rs:86-89`. The conclusion below, no `AddMatch`, is unchanged; the
reasoning that produced it was wrong. §11.1 row K5.

The port therefore emits **no** `AddMatch`. The daemon's
`<allow receive_type="signal"/>` (`bus/accessibility.conf.in:11`) makes every
broadcast arrive anyway. A Zig implementation that adds a match rule would
still work; one that omits it works too, but only for the same reason it works
in Rust.

## 5. The event flow

Two flows matter: a platform event becoming a tree update, and a tree update
becoming bus traffic. This section follows one node through both.

### Flow A: a platform focus change

1. The toolkit calls `accesskit_unix::Adapter::update_if_active(update_factory)`
   (`adapters/unix/src/adapter.rs:189-215`). It takes a write lock on
   `AdapterState` and calls `AdapterImpl::update` for the active case.
2. `Adapter::update` (`atspi-common/src/adapter.rs:533-539`) builds an
   `AdapterChangeHandler`, takes a write lock on the tree, and calls
   `tree.update_and_process_changes(update, &mut handler)`. The lock is
   dropped before the trailing `handler.emit_selection_changed()`.
3. `accesskit_consumer` walks the diff and calls back into
   `TreeChangeHandler`. For a focus change that is `focus_moved`
   (`adapter.rs:324-343`).
4. `focus_moved` finds the root window by role
   (`adapter.rs:599-607`, roles `AlertDialog`, `Dialog`, `Window`). On a
   focus entry it calls `window_activated` (`adapter.rs:551-574`), which
   emits `Event::Window { event: WindowEvent::Activated }`,
   `ObjectEvent::StateChanged(State::Active, true)`, and
   `ObjectEvent::ActiveDescendantChanged(root)`.
5. Still in `focus_moved`, it emits
   `ObjectEvent::StateChanged(State::Focused, true)` on the new node
   (`adapter.rs:335-336`) and `State::Focused, false` on the old node
   (`adapter.rs:340-341`).
6. `Adapter::emit_object_event` (`adapter.rs:501-507`) wraps the event in
   `Event::Object` and calls the callback.
7. The callback is `accesskit_unix::Callback`
   (`adapters/unix/src/adapter.rs:24-77`). It sends
   `Message::EmitEvent { adapter_id, event }` into the channel
   (`adapter.rs:70-75`). No D-Bus work happens on this thread.
8. The event loop thread takes the message (`context.rs:204-207`).
9. `process_adapter_message` matches `Event::Window` (`context.rs:264-277`)
   and calls `bus.emit_window_event` (`context.rs:272-275`).
10. `Bus::emit_window_event` (`bus.rs:398-417`) picks `Activate` or
    `Deactivate` (`bus.rs:409-412`), fills `any_data` with the window name,
    and calls `emit_event`.
11. `Bus::emit_event` (`bus.rs:482-504`) calls
    `conn.emit_signal(None, target.path(), interface, member, &body)`.
    Nothing waits for a reply, so this does not block.

Steps 4, 5, and 11 produce three signals on the bus: one `Activate`, one
`StateChanged` for `Active`, one `ActiveDescendantChanged`, and two
`StateChanged` for `Focused`.

### Flow B: a property change on an existing node

1. Steps 1 and 2 of Flow A.
2. `node_updated` fires (`atspi-common/src/adapter.rs:287-322`). It first
   computes the interface delta and sends register and unregister messages
   (`adapter.rs:307-314`).
3. It reads the window bounds and calls
   `new_wrapper.notify_changes(&bounds, adapter, &old_wrapper)`
   (`adapter.rs:315-316`).
4. `notify_changes` (`node.rs:593-604`) runs five checks in order:
   `notify_state_changes` (`node.rs:606-620`),
   `notify_property_changes` (`node.rs:622-671`),
   `notify_bounds_changes` (`node.rs:673-684`),
   `notify_children_changes` (`node.rs:692-713`), and
   `notify_document_changes` (`node.rs:686-690`).
5. `notify_state_changes` XORs the old and new `StateSet`, skips
   `State::Focused` (handled by `focus_moved`), and emits one
   `StateChanged` per remaining bit (`node.rs:609-619`).
6. `notify_property_changes` compares name, description, parent, role, and
   current value one at a time, and emits one `PropertyChange` per
   difference (`node.rs:623-671`). When the name changed and the node has a
   live region, it also emits `Announcement` (`node.rs:629-634`).
7. `notify_children_changes` diffs the old and new filtered child lists and
   emits `ChildrenChanged` per addition and per removal
   (`node.rs:692-713`). Note it does not compute the index for removals.
8. Back in `node_updated`, `emit_text_selection_change` runs
   (`adapter.rs:317`).
9. If the selected flag changed, `enqueue_selection_changed_if_needed`
   records the selection container (`adapter.rs:318-320`).
10. Still in `node_updated`, text diffing ran first, at `adapter.rs:288`.
    `emit_text_change_if_needed` (`adapter.rs:184-194`) compares the common
    prefix and suffix by Unicode scalar value and emits one `TextChanged`
    delete followed by one insert (`adapter.rs:121-181`).
11. After the write lock is dropped, `Adapter::update` calls
    `handler.emit_selection_changed()` (`adapter.rs:538`), which emits one
    `SelectionChanged` per recorded container (`adapter.rs:269-278`).
12. Every emission goes through `Callback` into the channel, and the event
    loop thread turns each one into `conn.emit_signal`. The wire calls are at
    `bus.rs:468-476` for cache signals and `bus.rs:490-499` for event signals.

### Flow C: a D-Bus method call coming in

1. A client sends `org.a11y.atspi.Action.DoAction(0)` to a node path.
2. zbus's object server routes it to the interface registered for that path
   (`bus.rs:134-137`).
3. `ActionInterface::do_action` (`action.rs:48-50`) calls
   `PlatformNode::do_action` (`node.rs:1119-1130`).
4. `do_action_internal` (`node.rs:824-838`) takes a read lock on the tree,
   locates the node, drops the lock at `node.rs:832`, then calls
   `Context::do_action` (`atspi-common/src/context.rs:76-78`).
5. `Context::do_action` locks a `Mutex<ActionHandlerWrapper>` and calls the
   toolkit handler (`atspi-common/src/context.rs:29-33`).
6. zbus sends the reply.

The handler runs on the event loop thread, so it is the same thread that
turns tree updates into signals. A handler that synchronously re-enters the
adapter would deadlock on the tree lock. The `drop(tree)` at `node.rs:832`
exists to make sure the lock is gone before the handler runs.

## 6. Zig implementation shape with goose v3.3.0

goose at tag `v3.3.0`, commit `8c6ee3a984a3b314bb921e3f8f6428a51a6d93e1`.
`minimum_zig_version = "0.16.0"`, no dependencies
(`/tmp/scratch/goose/build.zig.zon:1-17`). Pinned already in
`local://zaccesskit-deps.md`. Module names below are from that checkout.

### 6.1 Step by step

| Step in §2 or §5 | goose module and entry point |
|---|---|
| Connect to the accessibility bus | `connection.zig`, `Connection.initWithBackend(allocator, .Accessibility, io, vars, .threaded)`. `BusType.Accessibility` reads `AT_SPI_BUS_ADDRESS` first and falls back to `/run/user/{uid}/at-spi/bus_0` (`connection.zig:493-501`) |
| Resolve the address from the session bus | `proxy.zig`, `Proxy.init(conn, "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus")` then `.rawCall("org.a11y.Bus", "GetAddress", .{})` |
| Watch `IsEnabled` | `proxy.zig`, `Proxy.connectSignal` builds the `AddMatch` string itself (`proxy.zig:128`) and registers a typed callback. Use `connection.zig` `addMatch` (`connection.zig:1063-1077`) plus `registerSignalHandler` (`connection.zig:1162-1173`) when the match string must be `type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'` |
| Register the application root object | `connection.zig`, `registerObject(T, bus_name, path, user_data)` (`connection.zig:699-741`). It calls `requestName` first (`:701`), allocates one `T`, generates introspection XML through `xml_generator.zig` (`connection.zig:720`), and stores a `common.InterfaceWrapper` with the dispatch fn from `dispatcher.zig` `getDispatchFn`. **It binds no `Signal` field.** `Signal(T)` declares `name`, `interface` and `path` as ordinary mutable fields at `dbus_types.zig:10-12`, and `trigger` reads them at `:24`, so the port assigns all three at run time after it builds the object. §11.1 row K10 |
| Answer method calls | `dispatcher.zig`, `getDispatchFn(T)` (`dispatcher.zig:11`). It handles `Properties.Get`, `GetAll`, and `Set` (`:72-254`), then matches each method declaration whose first parameter is `*T` against the member name (`:255-319`) |
| `Embed` | `proxy.zig`, `Proxy.call("Embed", .{.{ unique_name, root_path }})`, which wraps `rawCall` (`proxy.zig:65-97`). Read with `MethodResult.expect` or `expectAlloc` (`proxy.zig:11-41`) |
| Emit a signal | `dbus_types.zig`, `Signal(T)` and `signal(name, T)`. `trigger(conn, payload)` builds the header and calls `conn.sendMessage` (`dbus_types.zig:8-49`) |
| Encode a body | `message_utils.zig`, `BodyEncoder.encode(allocator, values)` (`message_utils.zig:17-42`) |
| Decode a body | `message_utils.zig`, `BodyDecoder.decode` (`message_utils.zig:139-155`) or `decodeAlloc` (`:157-`) |
| Custom wire types | `value.zig`, `Value.Struct(S)` (`value.zig:524`), `Value.Tuple(T)` (`value.zig:453`), `Value.Variant(T)` (`value.zig:486`), or a hand-written `ser` method, which `Value.doesImplementSer` recognises first (`value.zig:239-250`) |
| Received signals | `connection.zig`, `dispatchUnsolicited` walks `signal_handlers` and calls each matching callback (`connection.zig:905-916`) |
| Read the generated introspection XML | `introspection.zig`, `Node`, `Interface`, `Method`, `Signal`, `Property` and the XML scanner (`:5-120`) |
| Message framing | `core.zig`, `Message.pack` (`core.zig:403-415`), `MessageHeader.pack` (`:239-289`), `MessageHeaderFieldValue.ser` (`:95-121`) |

`common.zig` supplies the two glue types: `SignalHandler` and
`InterfaceWrapper` (`common.zig:7-23`).

### 6.2 The wire types, expressed in goose

| AT-SPI type | Zig representation | Notes |
|---|---|---|
| `s` | `core.value.GStr` | `value.zig:86-92` |
| `o` | `core.value.GPath` | `value.zig:95-101` |
| `i` | `i32` | |
| `u` | `u32` | |
| `n` | `i16` | Not used by any member AccessKit touches. `NAnchors` is `i`; §11.1 row K3 |
| `b` | `bool` | |
| `d` | `f64` | |
| `(so)` | `struct { name: GStr, path: GPath }` with a `ser` method | The `(so)` signature needs `SIGNATURE` and `ser`; `Value.Struct` gives the wrapper but the field order must match |
| `(sa{sv})` | `struct { bus_name: GStr, path: GPath, values: std.StringHashMap(GVariant) }` with `ser` | `OwnedObjectAddress` is `(s, o)`, but the cache item wraps it in an `a{sv}`; see §6.4 |
| `a(so)` | `[]const struct { GStr, GPath }` | A slice pointer gives `a` |
| `au` | `[]const u32` | `StateSet` becomes a sorted-or-not slice; order is not contractual |
| `as` | `[]const GStr` | |
| `a{ss}` | `std.StringHashMap(GStr)` | `Value.isDict` recognises the `KV` shape (`value.zig:214-228`) |
| `a(ua(so))` | `[]const struct { u32, []const ObjectRef }` | |
| `v` | `value.value.GVariant` (`value.zig:162-186`) | `variants nest variants` |
| `siiva{sv}` | `struct { kind: GStr, detail1: i32, detail2: i32, any_data: GVariant, properties: std.StringHashMap(GVariant) }` with `ser` | The event body |
| `((so)(so)(so)iiassusau)` | `struct { object: ObjectRef, app: ObjectRef, parent: ObjectRef, index: i32, children: i32, ifaces: []const GStr, short_name: GStr, role: u32, name: GStr, states: []const u32 }` with `ser` | The cache item |

`GVariant` for `any_data` is where the effort goes. AccessKit writes five
distinct variants into the same slot: `(so)` for object references, `s` for
strings, `(iiii)` for rects, `u` for roles, `d` for values, and a bare `u32`
zero for events that carry nothing. `GVariant` is a tagged union
(`value.zig:139-186`) so this is a plain `switch`.

### 6.3 Gaps, and what has to be written

| # | Gap | Evidence | What to write |
|---|---|---|---|
| G1 | No way to remove a registered interface | `registered_interfaces` is only appended (`connection.zig:740`) and only drained in `close` (`:603-606`). No `unregisterObject` exists in `src/` | A `removeInterface` on the connection, plus an index from path to wrapper. §3.16 needs removal on every node deletion |
| G2 | No lookup index: every incoming method call scans the whole list | `dispatchUnsolicited` walks `self.registered_interfaces.items` comparing paths (`connection.zig:934-937`) | A `std.StringHashMap(usize)` from path to slot index. Without it, cost grows with tree size |
| G3 | `registerObject` always requests a well-known name | `connection.zig:701` `try self.requestName(bus_name)` | AccessKit must not own a name. Split registration from name acquisition, or pass the unique name and skip the request |
| G4 | Only `unix:path=` is parsed from a bus address | `SocketIterator.next` matches only the `path=` key (`connection.zig:1458-1473`) | Handle `unix:abstract=`, which the launcher emits at `bus/at-spi-bus-launcher.c:541`. Also accept `guid=` and reject nothing silently |
| G5 | Method names come from the Zig declaration name | `dispatcher.zig:264` `std.mem.eql(u8, member, decl.name)` | Either name the Zig functions `GetChildAtIndex` and so on, or write a hand-written dispatcher. See §6.5 |
| G6 | Error names are collapsed | `dispatcher.zig:298` sends `org.freedesktop.DBus.Error.Failed` with `@errorName(err)` as the message | The §3.15 mapping needs real error names: `UnknownObject`, `InvalidArgs`, `NotSupported` |
| G7 | No async method support | `grep -rn 'async\|await' src/` returns nothing | None needed. AccessKit's handlers are synchronous and short (§7) |
| G8 | No `ObjectManager` | Not in `src/` | None needed. AccessKit does not use it |
| G9 | `Properties.Set` emits `PropertiesChanged` unconditionally | `dispatcher.zig:205-237` | Harmless but wrong for AT-SPI. The `Application.Id` setter must not emit it |
| G10 | The introspection XML is missing AT-SPI's `version` property | `xml_generator.zig:106-125` emits one property per struct field | Add a `version: u32` field to each interface struct |
| G11 | No `AddAccessible` / `RemoveAccessible` shape in the library | The `Signal(T)` helper carries one payload type (`dbus_types.zig:9`) | `signal("AddAccessible", CacheItem)` works once `CacheItem` has `ser` and `SIGNATURE` |
| G12 | goose never learns its own unique name | `sayHello` binds the `Hello` reply at `connection.zig:572` and frees it at `:573`. No field and no accessor exist; `grep -rn "unique" src/` over the goose tree returns one hit, a doc comment at `proxy.zig:52` | **Blocker.** See §11.2 blocker B1. Not fixable from the port, because `Embed` needs the name |
| G13 | `Embed` with a plug name that is not the caller's own kills the registry | The plug is the caller's unique name (`bus.rs:88`). A mismatched plug aborts `at-spi2-registryd`; the launcher then restarts it | **Blocker.** See §11.2 blocker B2. A harness that hard-codes a unique name must be refused |

### 6.4 The `(sa{sv})` problem

Settled, not inferred. `xml/Cache.xml` types `CacheItem` as
`((so)(so)(so)iiassusau)`: the first three members are `(so)` object
references, and there is no `a{sv}` anywhere inside a cache item. In the whole
protocol `a{sv}` appears in exactly one place, as argument five of an event
body (§4). AccessKit agrees: its `OwnedObjectAddress`
(`atspi/object_address.rs:17-19`) serialises as a two-field `(so)` struct, and
`cache.rs:31-58` fills `object`, `app` and `parent` from it.

So `(so)` is the shape to implement, and the `a{sv}` is needed only as the
empty `properties` argument of an event body.

The Rust declaration this section used to cite,
`atspi-common-0.13.0/src/cache.rs:13-40`, and its claim that `CacheItem.object`
is an `ObjectRefOwned`, are **not on this host** and are therefore **unverified
here**; see §11.3 row U2. The shape does not depend on them. §11.1 row K11.

### 6.5 Naming: member name to Zig function name

This is a design decision, not a detail. Two options:

| Option | Shape | Cost | Risk |
|---|---|---|---|
| A. Name the Zig functions after the members: `pub fn GetChildAtIndex(self: *AccessibleInterface, index: i32) !ObjectRef` | Uses `dispatcher.getDispatchFn` unchanged | Zero extra code | Breaks the house naming rule (`AGENTS.md` §1: "fns `camelCase`"). Also collides with `GetState` on `Accessible` and `GetAttributes` on `Accessible` and `Document`, but those are separate structs, so no real collision |
| B. Write a hand-written dispatcher per interface that switches on the member string and calls a camelCase function | One `dispatch` function per interface, about 30 lines each | About 400 lines total | Must also handle `Properties`, `Introspect`, and error names, which means forgoing `dispatcher.zig` |

**Recommendation: option B.** It keeps the house naming rule, it is the only
way to get G6 right without patching goose, and it is where G1 and G2 land
anyway, because the hand-written dispatcher needs the path index that
`dispatchUnsolicited` does not provide. A port that names Zig functions
`GetChildAtIndex` has copied the upstream identifier, not the upstream
design.

### 6.6 Interaction with `zio`

goose is built on `std.Io`, not on `zio`. `local://zaccesskit-deps.md` leaves
this open and requires `docs/30-port-design.md` to decide. This document does
not decide it, but records what the choice costs:

- The event loop is a `select` over two sources (`context.rs:197-210`): a
  signal stream and a message channel. Under zio this is a select over a
  zio channel and a zio timer or a zio socket read. Under goose's own
  threading it is goose's `workerLoop` plus `dispatchLoop`
  (`connection.zig:1174-1212`, `:883-886`).
- `Connection.init` already takes `io: std.Io` as a parameter
  (`connection.zig:469`), so a zio-backed `std.Io` is a parameter swap, not a
  fork.
- goose's `.threaded` backend spawns its own `std.Thread`
  (`connection.zig:862-880`). That is two thread models in one process. The
  `.poll` backend avoids it and needs the caller to pump `dispatch()`
  (`connection.zig:311-338`), which fits a zio loop better but re-enters the
  reentrancy hazard in §7.

## 7. Threading and reentrancy

### 7.1 What blocks

| Call | Blocks? | Where |
|---|---|---|
| `Socket.Embed` | Yes | Awaited at `bus.rs:86-89` on the event loop thread. It is one round trip at startup |
| `BusProxy::GetAddress` | Yes | `bus.rs:45`, once at startup |
| `object_server().at` / `.remove` | No, from the caller's view | `bus.rs:188`, `bus.rs:250`. These mutate local state |
| `conn.emit_signal` | No | `bus.rs:469`, `bus.rs:491`. Fire and forget. zbus queues and returns |
| Tree read locks | Yes, briefly | `atspi-common/src/context.rs:68-70`, held only around a decode |
| `ActionHandlerWrapper` mutex | Yes | `atspi-common/src/context.rs:31`, held for the whole toolkit callback |
| `AppContext` write lock | Yes, briefly | `atspi-common/src/context.rs:84-86` |

### 7.2 Where a Zig task can await

In zio terms, an await point is safe when it holds no tree lock, no action
handler mutex, and no app-context lock. From the evidence:

- **Safe**: awaiting inside a D-Bus method handler, provided the handler has
  already dropped the tree read lock. `do_action_internal` drops it at
  `node.rs:832` before calling the handler. A Zig handler that needs to make
  its own outbound call must do the same.
- **Safe**: awaiting on the tree write lock, `adapter.rs:535`.
- **Not safe**: awaiting while holding `Context::tree` (`adapter.rs:535-537`),
  `Context::app_context`, or the action handler mutex
  (`atspi-common/src/context.rs:31`). The Rust code drops the tree lock
  before the handler runs for exactly this reason.

### 7.3 Signal delivery while a method call is in flight

In Rust, zbus runs its own executor, so the two are independent. The port
must preserve that property.

In goose `.threaded`, the property holds. `workerLoop` reads the socket, and
splits by message type: replies go into `pending_calls` (`connection.zig:1191-1200`),
everything else is pushed to `dispatch_queue` (`:1203-1206`), and
`dispatchLoop` handles it on a second thread (`:883-886`). So a signal
arriving while `callWithFds` is waiting on its futex (`connection.zig:1435-1437`)
is delivered by a different thread and does not stall the reply.

### 7.4 What happens if a signal handler issues a method call

**goose `.threaded`.** `dispatchUnsolicited` holds
`signal_handlers_mutex` for the whole loop (`connection.zig:908-915`), and the
handler is called inside that lock. If the handler calls `Proxy.call`, then:

- The write path is fine. `write_mutex` is a different mutex
  (`connection.zig:274`, taken at `:400`). `callWithFds` itself takes no lock
  that a dispatch thread holds.
- The reply is fine. `workerLoop` does not take `signal_handlers_mutex`.
- No deadlock. But the handler blocks a dispatch thread for the duration, so
  signal throughput drops to the latency of the outbound call.

**goose `.poll`, or the inline path in `callWithFds`.** `callWithFds` reads
messages itself and calls `dispatchUnsolicited` inline when the message is
not a reply (`connection.zig:1404-1432`). If a signal handler then calls
`Proxy.call`, that nested call reads from the same socket and can consume the
outer call's own reply, or an unrelated message, out of order. This is a
genuine hazard, and it is why the port must not use `.poll` with a signal
handler that calls out.

### 7.5 Other reentrancy notes

- `signal_handlers_mutex` is held while the callback runs. If the callback
  re-enters `registerSignalHandler` or `dispatchUnsolicited`, that is
  self-deadlock on a non-reentrant mutex. AccessKit never subscribes to an
  accessibility-bus signal, so the port must not either.
- `registered_interfaces` has no lock. `registerObject` appends to it
  (`connection.zig:740`) from the caller's thread while `dispatchUnsolicited`
  iterates it from a dispatch thread. AccessKit registers and removes
  interfaces from the event loop thread while a screen reader may be calling
  a method at the same instant. The port needs a mutex here. This is the same
  finding as G1, and it is a correctness bug, not only a performance one.
- `Map` and `MessageQueue` in goose both take `io: std.Io` for their
  condition variables (`connection.zig:24-71`, `:73-119`), so they compose
  with whatever `io` the connection was built with.

### 7.6 Ordering guarantees the port must keep

1. `register_interfaces` before any event for that node. The
   `node_updated` handler sends the interface delta at `adapter.rs:307-314`
   and the events at `adapter.rs:316`. Same channel, same order.
2. `emit_cache_add` after `register_interfaces`. `add_node`
   (`adapter.rs:49-82`) registers at `:60` and emits the cache event at `:61`.
3. `SelectionChanged` after every event that could have caused it. It is
   emitted last, after the tree lock is dropped, at `adapter.rs:538`.
4. `EmitEvent` for a cache change is unreachable as such:
   `context.rs:286-289` marks it `unreachable!` because cache changes travel
   as `EmitCacheAdd` and `EmitCacheRemove`.

The port must keep all four. A screen reader that receives
`StateChanged(checked)` before the interface that lets it query the new state
will cache a stale object.

## 8. Testability without a session bus

Three routes. All three need no session bus at all, because the port reads
`AT_SPI_BUS_ADDRESS` first (`bus.rs:43`) and never falls back to the session
bus when that variable is set.

### 8.1 Private bus, no session bus at all — recommended

Both `dbus-daemon` and `dbus-broker` are installed at `/bin`, verified with
`command -v dbus-daemon dbus-broker dbus-run-session`.

The a11y bus needs no session bus. Start a private daemon on a filesystem
socket in the build directory, write the address into `AT_SPI_BUS_ADDRESS`,
run the test, kill the daemon. No user session, no display, no
`at-spi-bus-launcher`.

```sh
sock="$PWD/.zig-cache/a11y-test-socket"
dbus-daemon --nofork --print-address=3 --address="unix:path=$sock" 3>address.txt &
AT_SPI_BUS_ADDRESS="unix:path=$sock" zig build test
```

Use the same policy as the real bus, because the real policy is what the
implementation depends on: `bus/accessibility.conf.in:11` allows all signals
through, and `:15` allows any name to be owned. A default-policy daemon
forbids nothing by default, which is close enough, but a config copied from
`bus/accessibility.conf.in` removes the doubt.

What this proves:

- `Hello`, the auth handshake, framing, and serialisation against a real
  daemon.
- `Embed` returning a desktop reference, and `Id` round-tripping through
  `Properties.Set`.
- `GetItems`, `GetChildren`, and `GetState` decoding on the client side.
- That signals actually arrive without `AddMatch`. This is the single most
  valuable assertion in the whole suite, because it is a property of the
  daemon policy that the code silently relies on.
- A real client against the port. `python3` plus `dbus-next`, or `busctl`, if
  present, closes the loop. `command -v busctl` decides.

What it does not prove: that the code works against a **GNOME** registry. The
daemon has no registry, so `Embed` needs a stub responder. That splits the
test in two: a daemon-backed suite that stubs `Embed`, and the suite in §8.2.

The stub must record the plug it was handed and nothing may assert that the
plug equals a literal, because a real `Embed` with a foreign plug name
terminates `at-spi2-registryd`. §11.2 blocker B2.

### 8.2 Fake peer over a socket pair — recommended

Write a Zig test peer. Bind a `AF_UNIX` listener on a path under
`.zig-cache`, point `AT_SPI_BUS_ADDRESS` at it, and speak the protocol from
the test process.

The peer must answer four things:

1. The auth handshake, because `Connection.initWithBackend` calls `auth()`
   unconditionally (`connection.zig:419-463`): send `OK` to
   `AUTH EXTERNAL …`, answer `NEGOTIATE_UNIX_FD` with `AGREE_UNIX_FD`, then
   read `BEGIN`.
2. `Hello` on `/org/freedesktop/DBus`. `sayHello` (`connection.zig:549-574`)
   waits for the reply, binds it to a local at `:572` and frees it at `:573`. It
   reads nothing out of it. The peer must send one.
3. `Embed` on `org.a11y.atspi.Registry`. Return a fixed `(so)`, so the
   desktop reference is deterministic.
4. Nothing else. AccessKit sends no other client call.

The peer must not send `RequestName`, and it must tolerate the fact that the
port sends none.

That peer also settles blocker B1, and it cannot do so from outside the
process. The `Hello` reply goose throws away is the only place the client's own
unique name exists, so a peer that answers `Hello` cannot see it, and a test
peer can never assert that the name the port passes to `Embed` is the name the
bus assigned to it. That assertion is the one §8.3 cannot supply either. The
`sayHello` fix is about five lines at one known location and it is the first
thing the AT-SPI milestone needs. §11.2 blocker B1.

Then the peer drives the port from the other side:

| What the peer sends | What the port must do |
|---|---|
| `org.a11y.atspi.Accessible.GetState` on a node path | Reply `au` with the expected bits |
| `org.a11y.atspi.Cache.GetItems` | Reply with the expected item count and first item |
| `org.a11y.atspi.Action.DoAction` with index 0 | Reach the toolkit handler |
| `org.a11y.atspi.Accessible.GetChildAtIndex` with a negative index | Reply `InvalidArgs` |
| A call on a path that was never registered | Reply `UnknownObject` |
| `Introspect` on the cache path | Return XML containing all four interfaces at that path |

And the peer captures what the port emits:

| Signal | Assertion |
|---|---|
| `Cache.AddAccessible` after a node is added | Exactly one, right object reference |
| `Cache.RemoveAccessible` after a node is removed | Exactly one |
| `Event.Object.StateChanged` with `kind` `focused` | One per focus move, old node `0` then new node `1` |
| `Event.Object.PropertyChange` with `kind` `accessible-name` | Fires only when the name differs |
| `Event.Object.ChildrenChanged` with `kind` `add` | `detail1` equals the child index |
| `Event.Window.Activate` | Fires on focus entry, before `StateChanged(active)` |
| `Event.Document.LoadComplete` | Fires once when a busy document goes idle |

This route needs no external binary, so it runs in a container and in CI, and
it is deterministic because the peer controls both directions. It is the
route that satisfies the house rule "wire compatibility is a test, not a
comment" (`AGENTS.md` §2): the peer's expected byte strings are golden
vectors.

The one thing a fake peer cannot prove is that the real registry's `Embed`
reply shape is what the port expects. Fix that with a recorded fixture: one
captured `Embed` reply from a real bus, committed as bytes, replayed by the
peer. No Rust needed to produce it; capture it once with `busctl` against a
real session and commit the file.

### 8.3 Recorded transcripts — supplementary

A transcript is a byte stream. Two ways to use one:

- **Replay as the peer.** The §8.2 peer reads the recorded stream and writes
  it verbatim instead of generating replies. This catches any drift in the
  port's parser against bytes a real daemon produced.
- **Assert on the port's output.** The peer writes everything it receives to
  a file, and the test compares against a committed transcript.

Recording is a manual, one-time act: run against a real bus once, capture with
`busctl --monitor`, commit. `docs/50-verification.md` owns the procedure. The
port must never generate a transcript from Rust. That keeps the project free
of `cargo`.

### 8.4 What is not viable

| Idea | Why not |
|---|---|
| Use `dbus-run-session` for the session bus | It starts a session bus, but the a11y bus is a different daemon with a different policy. Two daemons for no gain |
| Use `at-spi-bus-launcher` | It reads the X11 root window property and needs a display (`bus/at-spi-bus-launcher.c:182-241`). Fails headless |
| Ask a real screen reader to verify | Non-deterministic and needs a session. Keep it as a manual smoke test in `docs/50-verification.md`, never as a gate |
| `goose`'s own `src/tests/` as a model | Those are run apps, not `zig build test` targets (`goose/build.zig:21-35`). They need a live bus. Write new tests |

### 8.5 The seam that makes all of this possible

goose does not accept an already-connected socket. `Connection.init` and
`initWithBackend` both resolve an address and connect themselves
(`connection.zig:469-518`). So the port cannot be handed a socket pair.

`AT_SPI_BUS_ADDRESS` is the seam. Route 8.1 and route 8.2 both set it to a
filesystem path, and `SocketIterator` parses `unix:path=` today
(`connection.zig:1458-1473`). The port needs one addition for tests, and it
is the same fix as G4: a full D-Bus address parser that also handles
`unix:abstract=`.

If the port instead opens its own connection abstraction, that abstraction
must take a `std.Io` and an address string, both explicit, and must be the
only place a socket is created. That is what makes §8.2 a two-line test
change rather than a redesign.

## 9. House rules

| Rule (`AGENTS.md` §1-§2) | Status for this subject | Action for the port |
|---|---|---|
| `io: std.Io` threaded explicitly | **Fits.** `Connection.init` takes `io` (`connection.zig:469`) and `MessageQueue` takes it too (`:80`) | Thread `io` from the adapter entry point. Do not capture it |
| Allocators as parameters | **Fits.** `Connection.init(allocator, …)` | Pass the same allocator the adapter already has |
| Explicit error sets, no `anyerror` in APIs | **Fights.** goose's public surface is `anyerror!`: `dispatcher.zig:11` returns `anyerror!DispatchResult`, `proxy.zig:65` returns `!MethodResult` with inferred error sets | Wrap every goose entry point in a `zbus.Error` set of our own, and map with `inline for` over `@typeInfo`. §6.3 G6 also needs real D-Bus error names |
| State as a parameter, not a capture | **Partly fights.** `Callback` holds a `Sender<Message>` (`adapters/unix/src/adapter.rs:24-30`) and `AdapterState` holds `Arc<Mutex<…>>` (`adapters/unix/src/adapter.rs:80-121`) | Keep the Rust split. The adapter owns a handle; state lives behind an explicit `*Context`, as `PlatformNode` already does via `Weak<Context>` (`node.rs:709-721`) |
| Loops have fixed upper bounds | **Fits and needs help.** `goose`'s `workerLoop` and `dispatchLoop` are unbounded (`connection.zig:883-886`, `:1174-1212`) | They are vendor code. Our own loops: the tree walk is already bounded by the tree. State the bound |
| No backwards compatibility | **Fits.** §3.14 lists members AccessKit omits. Do not add them | Keep the omission list as a test: introspect and assert the exact member set |
| Network logic is pure over bytes | **Fits.** `EventBodyBorrowed` construction (`bus.rs:282-395`) is pure data assembly; `notify_*` (`node.rs:606-713`) is pure diffing | Split each `emit_*` into a pure `encode_event(event) -> EncodedSignal` and an impure `send(EncodedSignal)`. Then the first half is testable without any bus |
| Comptime exhaustiveness over wire enums | **Fits.** `State`, `Role`, `Interface`, `CoordType`, `Granularity`, `ScrollType`, `RelationType` are all finite | Declare them as Zig enums with explicit values, and sweep them at comptime |
| Wire compatibility is a test | **Needs the golden vectors of §8.2-§8.3** | Commit captured bytes. Never generate them from Rust |

## 10. Open items for the design wave

1. The `zio` versus `std.Io` decision. `local://zaccesskit-deps.md` requires it
   to be settled in `docs/30-port-design.md`. §6.6 lists the costs.
2. Option A or option B of §6.5. This document recommends B.
3. Whether the port owns the `Event.Object` body as five loose fields, as a
   tagged union, or as a struct with a `ser` method. All three produce the same
   bytes; the choice is about how many illegal states the type admits.
4. Whether `notify_*` is split into pure diff and impure send, per the last
   row of §9. The split is cheap and is what makes §8.2 assert on pure logic.
5. Whether the `sayHello` fix of §11.2 blocker B1 rides in the goose patch
   step or in a wrapper the port owns. It cannot be a wrapper, because the
   reply is destroyed inside `Connection.initWithBackend` before it returns.
   This is the first thing the AT-SPI milestone needs and it is not optional.
6. Whether `docs/26` section 4 is corrected, or `docs/13` is. The two records
   give incompatible event-body signatures. §4 settles it at five arguments
   from the XML; `docs/26` was measured against a peer that built its own
   body, so its `siivso` is a defect in the probe rather than in the protocol.

---

## 11. Corrections, 2026-10-05

Every claim in §3 and in the earlier numbering was re-read at the pinned
upstream on **2026-10-05**, against the source rather than against a
transcription of it, and eleven of them did not survive. The
`docs/41-atspi-build-map.md` section 1 record holds the same measurements;
where the two disagree the source wins, and this section is the source's
answer written into the document it corrects.

Four of the eleven are load-bearing: a wire type, a member that lies about
what it does, a line count, and the shape of every event signal the adapter
sends. Two more blockers are recorded in §11.2, and three claims are recorded
in §11.3 as unsettled, because no source on this host settles them.

**Where the readings were taken.** Upstream AccessKit at
`466e24e252103f4d82bd6fbab98141b551e46e0c`, goose at tag `v3.3.0` commit
`8c6ee3a`, both under `/tmp/scratch/`. The AT-SPI2 reference XML
is read from `xml/Event.xml` and `xml/Cache.xml`. **`xml/Event.xml` was read on
this host on 2026-10-05** and every event-signal count and signature below is
measured from it. `xml/Cache.xml` and `xml/Socket.xml` are cited from the
fetch recorded in §0 and were not re-read here; network egress to
`gitlab.gnome.org` is not available on this host.

### 11.1 Eleven corrections

#### K1. `Application.Version`, section 3.14

**Was:** section 3.14 listed `Application.ToolkitVersion` (`s`) among the
members of the standard interfaces AccessKit does not export.

**Now:** not listed, because AccessKit exports it. `xml/Application.xml` calls
the property `ToolkitVersion`; AccessKit's accessor is
`fn version(&self) -> fdo::Result<String>` at
`adapters/unix/src/atspi/interfaces/application.rs:20-23`, so §0 "Property
naming" publishes it on the wire as `Version`. Section 3.2 was already right.
A port that trusted the omission list would name a property upstream never
sends. Evidence: `application.rs:13` `#[interface(name =
"org.a11y.atspi.Application")]`, `:20` `fn version`, `:24` `fn atspi_version`.

#### K2. The event body is `siiva{sv}`, five arguments, section 4

**Was:** "`any_data: Value`, `properties` (skipped on the wire)", and the
signature `siiva{sv}`.

**Now:** the signature was right and the fifth argument was wrong to drop.
`xml/Event.xml` declares `s`, `i`, `i`, `v`, `a{sv}` on every signal of
`org.a11y.atspi.Event.Object`, `org.a11y.atspi.Event.Window` and
`org.a11y.atspi.Event.Document`. Measured here on 2026-10-05: all seven event
interfaces in that file, every `<signal>` in each, join to `siiva{sv}`, with no
exception. `org.a11y.atspi.Event.Object` holds 22 of them.

The file's header comment says the dictionary "should be empty" and is
"reserved for future use". That is a statement about its contents. The argument
is on the wire.

`docs/26` section 4 records this signal as `siivso`. It was measured against a
peer that built its own four-argument body and delivered it to the sender, so
the four arguments are a defect in that probe, not a variant of the protocol.
One of the two records had to be wrong; the XML settles it.

#### K3. `Hyperlink.NAnchors` is `i`, not `n`, sections 3.9 and 6.2

**Was:** "`n` (i16) read", and section 6.2 mapped the Zig type `n` to
`NAnchors`.

**Now:** `i`. `adapters/unix/src/atspi/interfaces/hyperlink.rs:28` declares
`fn n_anchors(&self) -> fdo::Result<i32>`, and the provider is `pub fn
n_anchors(&self) -> Result<i32>` at
`adapters/atspi-common/src/node.rs:1242`, whose body is `if node.url().is_some()
{ Ok(1) } else { Ok(0) }`. So the property is `i`, and its value is `1` when the
node has a URL and `0` when it does not. A port that encodes `i16` sends the
wrong signature for every link, and no AT-SPI client can read it.

#### K4. `Selection.ClearSelection` never clears, section 3.11

**Was:** "Clear the whole selection".

**Now:** always `false`, and it never clears anything.
`adapters/atspi-common/src/node.rs:1386-1389`:

```rust
pub fn clear_selection(&self) -> Result<bool> {
    // We don't support deselecting all children at once.
    Ok(false)
}
```

The member is exported, it answers, and it declines. A port that implements it
honestly behaves like upstream; a port that implements the name instead of the
body gains a capability AccessKit does not have.

#### K5. `Embedded` and `Unembed` are methods, not signals, section 4.5

**Was:** "`Socket.Embedded` and `Socket.Unembed` exist in `xml/Socket.xml` but
AccessKit never subscribes to them."

**Now:** they are declared as `<method>`, not `<signal>`, in `xml/Socket.xml`.
The socket calls them on the plug, so only a plug implements them. AccessKit is
the plug and exports neither, which is consistent:
`adapters/unix/src/atspi/interfaces/` holds no `Socket` module, and the adapter's
only use of that interface is the one outbound `Embed` at
`adapters/unix/src/atspi/bus.rs:86-89`. The conclusion the sentence supported,
that the port emits no `AddMatch`, is unchanged. The reasoning behind it was
wrong.

#### K6. `org.a11y.atspi.Cache` declares two more members, section 4.4

**Was:** section 4.4 listed `AddAccessible` and `RemoveAccessible` as the
signals of `org.a11y.atspi.Cache`.

**Now:** `xml/Cache.xml` also declares a `Ready` signal, added in Cache version
2, and a `version` property of type `u`. AccessKit exports neither; the two
signals at `bus.rs:441-446` and `bus.rs:448-461` are the whole of it, and
`interfaces/cache.rs:108-113` is the whole of the interface.

The consequence is behavioural, not cosmetic. A client that subscribes to
`org.a11y.atspi.Cache.Ready` and waits for it before calling `GetItems` waits
forever against this adapter. A client that calls `GetItems` on the cache path
directly is unaffected.

#### K7. `atspi-common` is 4417 lines, section 0

**Was:** "`wc -l` over `adapters/atspi-common/src/*.rs` gives 5226 lines in
total".

**Now:** 4417, across 13 files. `wc -l` over
`adapters/unix/src/*.rs` gives 809, and 4417 + 809 = 5226, so the figure
measured the two crates together and named one. Measured on this host on
2026-10-05; the per-file figures are in the `docs/41` section 0.1 table.

#### K8. `add_node` registers at `:60` and emits at `:61`, section 7.6

**Was:** "`add_node` (`adapter.rs:49-81`) registers at `:57` and emits the cache
event at `:58`."

**Now:** `fn add_node(&mut self, node: &NodeRef)` starts at
`adapters/atspi-common/src/adapter.rs:49` and closes at `:82`. It calls
`self.adapter.register_interfaces(node.id(), interfaces)` at `:60` and
`self.adapter.emit_cache_added(node.id())` at `:61`. The two lines cited were
neither the function's start nor either call. The ordering guarantee this row
carries, register before emit, is unaffected; the citation a port would have
followed was not.

#### K9. `register_root_node` is at `bus.rs:76`, section 2 step 4

**Was:** `adapters/unix/src/atspi/bus.rs:73   async fn register_root_node(&mut
self) -> Result<()> {`

**Now:** line 76. The same paragraph gave the whole block as `bus.rs:77-115`; it
is `bus.rs:76-118`. Line 73 is inside `fn unique_name(&self)`, which is what
made the slip: the two are adjacent, and the unique-name accessor is the one
that blocker B1 is about.

#### K10. `Signal(T)` binds nothing at compile time, section 6.1

**Was:** `registerObject` "binds `Signal` fields".

**Now:** it binds nothing, and cannot. `Signal(T)` at
`/tmp/scratch/goose/src/dbus_types.zig:8` returns a struct with
three ordinary mutable fields, `name` at `:10`, `interface` at `:11` and `path`
at `:12`, and `trigger` reads all three at `:24` when it builds the header. A
`Signal` value is a plain struct a caller constructs and mutates, so the port
assigns all three at run time after it builds the object. This is a small
freedom, not a cost: a runtime-computed member name is roughly ten lines and no
patch. It also means the port cannot rely on goose to produce an AT-SPI member
name from a Zig declaration name, which is gap G5.

#### K11. `CacheItem` is `((so)(so)(so)iiassusau)`, settled, section 6.4

**Was:** `[INFERENCE] — the XML and the Rust type agree; no running instance was
inspected.`

**Now:** settled, and the inference marker is gone. `xml/Cache.xml` types
`CacheItem` as `((so)(so)(so)iiassusau)`, three `(so)` object references, two
`i`, then `as`, `s`, `u`, `s`, `au`. There is no `a{sv}` anywhere inside a cache
item. In the whole protocol `a{sv}` appears in exactly one place: argument five
of an event body (§4, K2). AccessKit agrees, since its `OwnedObjectAddress` at
`adapters/unix/src/atspi/object_address.rs:17-19` serialises as a two-field
`(so)` struct and `interfaces/cache.rs:31-58` fills `object`, `app` and `parent`
from it.

The remaining `[INFERENCE]` in this section, that `CacheItem.object` is an
`ObjectRefOwned` in a crate that is not on this host, is withdrawn as
unverifiable and moved to §11.3 row U2. The shape did not need it.

### 11.2 Two blockers

Neither of these is a gap the port can code around. Both were absent from this
document until 2026-10-05 and both decide whether the adapter can work at all.

#### B1. goose v3.3.0 never learns its own unique name, so the port cannot register

**What happens.** `Connection.initWithBackend` calls `sayHello` before it
returns. `sayHello` at
`/tmp/scratch/goose/src/connection.zig:549` builds the `Hello`
call, sends it, waits for the reply, binds it at `:572` and frees it at `:573`.
It reads nothing out of the reply. The reply body is the client's own unique
bus name, and it is the only place that name exists.

**There is no accessor.** No field holds it and no function returns it.
`grep -rn "unique" src/` over the goose tree at tag `v3.3.0` returns one hit,
a doc comment at `proxy.zig:52`. `connection.zig:657-658` discards a reply the
same way.

**Why it blocks the port.** A D-Bus client cannot own a well-known name, and it
cannot be addressed by anyone, including itself, without its unique name.
`adapters/unix/src/atspi/bus.rs:88` passes `self.unique_name().as_str()` as the
plug half of the `Embed` argument, and `xml/Socket.xml` requires the plug to be
"a string for the unique bus name of the application". Without the name the
port cannot call `Embed`, cannot register, and therefore exports nothing that a
screen reader can reach.

**The fix.** The same class as the `O_NONBLOCK` fix: keep the reply, store the
`s` body, expose a getter. About five lines at one known location. It cannot
live in the port, because the reply is destroyed inside `initWithBackend` before
the caller holds the `Connection`. It has to be a goose patch, carried with its
own assertion, and the port may depend on that patch for the AT-SPI adapter.

#### B2. `Socket.Embed` with a foreign plug name kills `at-spi2-registryd`

**What happens.** Called with any plug name other than the caller's own,
`Embed` aborts the `at-spi2-registryd` process. The launcher restarts it, so
the name then reads `(activatable)`. Reproduced twice on this node against the
live bus at `unix:path=/run/user/33156/at-spi/bus`, with `Introspect` on the
same object path and the same `IsEnabled` value as the control that leaves the
process running:

```text
$ pgrep -f 'at-spi2-registryd'
... 46843
$ busctl --address=unix:path=/run/user/33156/at-spi/bus introspect \
    org.a11y.atspi.Registry /org/a11y/atspi/accessible/root
Failed to parse bus message: No such device or address
$ pgrep -f 'at-spi2-registryd'
... 46843
$ busctl --address=unix:path=/run/user/33156/at-spi/bus call \
    org.a11y.atspi.Registry /org/a11y/atspi/accessible/root \
    org.a11y.atspi.Socket Embed ss ":1.12345" "/org/a11y/atspi/accessible/root"
Call failed: Remote peer disconnected
$ pgrep -f 'at-spi2-registryd'
        (46843 is gone)
```

**Why it matters to the port.** Three consequences, and each one is a design
constraint rather than an observation.

| Consequence | What it forces |
|---|---|
| A harness that substitutes a literal unique name destroys the accessibility registry on the developer's machine | Such a test must be refused, not written. §8.1's stub records the plug it was given and asserts nothing about its value |
| `busctl` cannot supply its own unique name, because a `busctl` process's unique name is not the caller's to choose | The `Embed` integration test can only be written in Zig, from inside the process that owns the connection |
| goose does not hold that name at all (B1) | The one assertion that would catch a wrong plug, that the name passed to `Embed` equals the name the bus assigned, is not writable until B1 is fixed |

**Never call `Embed` with a plug that is not `self.uniqueName()`.** Not in a
test, not in a fixture, not in a golden-vector replay. The registry is a
per-user process and the failure is not recoverable from the client side.

### 11.3 Three claims that this host cannot settle

Three claims in this document cite `atspi-common-0.13.0`, a crates.io
dependency. **There is no crates.io cache on this host**, no
`~/.cargo/registry`, and no copy of the crate anywhere in the trees searched.
They are recorded as unsettled rather than corrected, and rather than deleted,
because each one is a thing an implementer will need and each one can be
settled cheaply by a single fetch. Nothing below is asserted either way.

| Id | Claim | Where it is cited | What is already established | What would settle it |
|---|---|---|---|---|
| U1 | `EventBodyBorrowed` field names and their defaults | `atspi-common-0.13.0/src/events/event_body.rs:188-210`, cited at §0 and §4 | The wire shape. `xml/Event.xml` gives `siiva{sv}` with five arguments on every event signal, measured here on 2026-10-05 (K2) | Fetch `atspi-common-0.13.0` and read that range. It settles the field names and the `Default` impl, and nothing about the wire shape, which is already settled |
| U2 | `CacheItem` declaration order, and that `CacheItem.object` is an `ObjectRefOwned` | `atspi-common-0.13.0/src/cache.rs:13-40`, cited at §3.4 and §6.4 | The field order and the signature. `xml/Cache.xml` gives `((so)(so)(so)iiassusau)` and shows no `a{sv}` inside a cache item (K11) | Fetch `atspi-common-0.13.0` and read that range. It settles whether the declared order matches the XML's and what type `object` carries |
| U3 | `State::to_static_str` and the ten AT-SPI state strings | `atspi-common-0.13.0/src/state.rs:231-282`, cited at §4.1 | Nothing. The strings are the `kind` argument of `Event.Object.StateChanged`, and no source on this host enumerates them | Fetch `atspi-common-0.13.0` and read that range, or run a screen reader and capture one `StateChanged`. The capture is the better test, because it is the strings the client accepts |

U3 is the one that will bite first. `StateChanged` is emitted at
`adapters/unix/src/atspi/bus.rs:361-366` on every state transition in a
tree, and its first argument is the string U3 names. A port that guesses those
strings emits signals every client silently discards.

### 11.4 What changes for the port

Five things, and nothing here is a matter of taste.

| # | Change | Because |
|---|---|---|
| 1 | Encode `Hyperlink.NAnchors` as `i` and emit `1` or `0` | K3. The old `n` breaks every link |
| 2 | Implement `Selection.ClearSelection` as `Ok(false)` | K4. It is the exported behaviour, not a missing feature |
| 3 | Emit five-argument event bodies, the fifth an empty `a{sv}` | K2. Four arguments is a body no client decodes |
| 4 | Assign `Signal.name`, `Signal.interface` and `Signal.path` at run time | K10. goose binds nothing, so this is a plain struct |
| 5 | Take the `sayHello` goose patch, and refuse any test that hard-codes a unique name | B1 and B2. Without B1 the adapter cannot register; without B2 a test destroys the user's accessibility registry |

The three unsettled claims in §11.3 are not on this list, because none of them
changes what the port writes. Each one changes what it asserts.
