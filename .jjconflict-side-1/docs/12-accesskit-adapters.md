# AccessKit adapters: research corpus

**Consumed by:** `docs/30-port-design.md` (module and interface design), `docs/31-c-abi-design.md`
(the C ABI surface the adapters must expose), and `docs/40-plan.md` (milestone order and
adapter priority).

All paths in this document are relative to
`/tmp/scratch/accesskit`, at commit `466e24e252103f4d82bd6fbab98141b551e46e0c`.
All line counts come from `wc -l`. All `path:line` references were read from the checked-out
source. Anything not directly observed is marked `[INFERENCE]`.

**Two constraints bind every recommendation in this document.**

1. The ported project must build with no Rust toolchain. No `Cargo.toml`, no `Cargo.lock`, no
   `build.rs`, no `cbindgen`, no `cargo` invocation, at any point. Section 11 lists every
   construct in the adapters that exists only because of Rust and names its Zig replacement.
2. A Zig implementation is preferred over C in every case. The decision order is:
   rung 1 Zig standard library, rung 2 a Zig package pinned in `build.zig.zon`, rung 3 a Zig
   `translate-c` binding to a system C library, rung 4 a hand-written C shim. Section 9 places
   each host dependency on that ladder.

---

## 1. Adapter inventory

### 1.1 Line counts, from `wc -l`

| Crate | Files counted | Total lines |
|---|---|---|
| `accesskit_unix` | `src/adapter.rs` 276, `src/context.rs` 306, `src/executor.rs` 158, `src/lib.rs` 27, `src/util.rs` 42 | 809 |
| `accesskit_unix` atspi subtree | `src/atspi/bus.rs` 525, `src/atspi/mod.rs` 13, `src/atspi/object_address.rs` 45, `src/atspi/object_id.rs` 79 | 662 |
| `accesskit_unix` atspi interfaces | `accessible.rs` 246, `action.rs` 51, `application.rs` 39, `cache.rs` 311, `component.rs` 76, `document.rs` 60, `editable_text.rs` 52, `hyperlink.rs` 63, `image.rs` 50, `mod.rs` 47, `selection.rs` 82, `text.rs` 163, `value.rs` 49 | 1289 |
| `accesskit_atspi_common` | `action.rs` 14, `adapter.rs` 824, `callback.rs` 15, `context.rs` 122, `error.rs` 33, `events.rs` 78, `filters.rs` 6, `lib.rs` 33, `node.rs` 2065, `rect.rs` 37, `simplified.rs` 977, `text_attributes.rs` 79, `util.rs` 134 | 4417 |
| `accesskit_windows` (library) | `adapter.rs` 673, `context.rs` 98, `filters.rs` 8, `lib.rs` 22, `node.rs` 1539, `subclass.rs` 204, `text.rs` 652, `util.rs` 536, `window_handle.rs` 32 | 3764 |
| `accesskit_windows` (tests) | `tests/mod.rs` 337, `tests/simple.rs` 198, `tests/subclassed.rs` 177 | 712 |
| `accesskit_macos` | `adapter.rs` 295, `context.rs` 103, `event.rs` 335, `filters.rs` 6, `lib.rs` 25, `node.rs` 1367, `patch.rs` 93, `subclass.rs` 273, `util.rs` 108 | 2605 |
| `accesskit_ios` | `adapter.rs` 514, `context.rs` 95, `event.rs` 270, `filters.rs` 130, `lib.rs` 41, `node.rs` 1076, `subclass.rs` 324, `util.rs` 110 | 2560 |
| `accesskit_android` | `action.rs` 85, `adapter.rs` 906, `event.rs` 419, `filters.rs` 6, `inject.rs` 471, `lib.rs` 19, `node.rs` 447, `util.rs` 251 | 2604 |
| `accesskit_winit` | `src/lib.rs` 267, `platform_impl/android.rs` 49, `ios.rs` 55, `macos.rs` 55, `mod.rs` 55, `null.rs` 24, `unix.rs` 77, `windows.rs` 49 | 631 |

Largest single files in the whole adapter set: `atspi-common/src/node.rs` 2065,
`windows/src/node.rs` 1539, `macos/src/node.rs` 1367, `ios/src/node.rs` 1076,
`android/src/adapter.rs` 906, `atspi-common/src/simplified.rs` 977, `windows/src/adapter.rs` 673,
`windows/src/text.rs` 652.

### 1.2 One row per adapter

| Adapter | Targets | Kind | C or system libraries linked | System libraries used through FFI | Total lines |
|---|---|---|---|---|---|
| `accesskit_unix` | Linux, plus the BSDs listed in `adapters/winit/Cargo.toml:34` (`dragonfly`, `freebsd`, `openbsd`, `netbsd`) | platform implementation | none | none. No `extern "C"`, no `#[link]`, no `dlopen`, no `build.rs`. It speaks D-Bus over a Unix socket through the pure-Rust `zbus` 5.19 crate (`adapters/unix/Cargo.toml:25`) | 2760 |
| `accesskit_atspi_common` | none. It is a translation library shared by the unix adapter and any other AT-SPI consumer | platform-neutral core | none | none | 4417 |
| `accesskit_windows` | Windows, docs.rs default target `x86_64-pc-windows-msvc` (`adapters/windows/Cargo.toml:16`) | platform implementation | `uiautomationcore.dll` (loaded by the OS, not by a link flag) | Win32: `user32`, `ole32`, `gdi32`, `kernel32`, `oleaut32` | 3764 |
| `accesskit_macos` | macOS, docs.rs default target `x86_64-apple-darwin` (`adapters/macos/Cargo.toml:15`) | platform implementation | none. The only `extern "C"` in the crate is a `dlsym` declaration in the iOS crate, not this one | AppKit, Foundation, CoreGraphics (reached only through an ObjC message; see 6.1) | 2605 |
| `accesskit_ios` | iOS, docs.rs default target `aarch64-apple-ios` (`adapters/ios/Cargo.toml:15`) | platform implementation | `libSystem` for `dlsym` (`adapters/ios/src/util.rs:73-75`) | UIKit, Foundation, CoreGraphics | 2560 |
| `accesskit_android` | Android, minimum SDK 30 per the example Gradle build | platform implementation | none in the library. The only `#[link(name = "log")]` is in `adapters/android/examples/hello_world.rs:132`, which is an example, not the adapter | none. The adapter is pure JNI through the `jni` 0.21.1 crate (`adapters/android/Cargo.toml:21`) | 2604 |
| `accesskit_winit` | all of the above, selected at compile time | toolkit integration | none itself; it delegates | none itself | 631 |

The only adapter that names its own third-party libraries is `accesskit_windows`, which uses the
`windows` 0.62.0 crate with ten feature flags
(`adapters/windows/Cargo.toml:26-39`). Every other adapter uses a pure-Rust binding crate for its
platform: `zbus` + `atspi` on unix, `objc2` + `objc2-app-kit` + `objc2-foundation` on macOS,
`objc2` + `objc2-ui-kit` + `objc2-foundation` on iOS, `jni` on Android.

---

## 2. The unix adapter in detail

### 2.1 Correction to the task brief: there is no X11 path and no Wayland path

The task brief asked for "the X11 and Wayland paths separately". The checked-out source has
neither. Command and output:

```
$ grep -rn 'xcb\|wayland\|X11\|xlib\|xkb\|wl_' adapters/unix/src/ adapters/unix/Cargo.toml
adapters/unix/src/adapter.rs:172:    /// Wayland, calling this method only makes sense under X11.
```

One hit, and it is a doc comment. There is no `extern "C"` block, no `#[link]` attribute, no
`dlopen`, and no `build.rs` anywhere in `adapters/unix`. `adapters/unix/Cargo.toml` lists no
X11 or Wayland crate.

The whole of the X11 and Wayland connection is that single sentence, at
`adapters/unix/src/adapter.rs:172`, inside the doc comment on `set_root_window_bounds`:

```rust
/// Set the bounds of the top-level window. The outer bounds contain any
/// window decoration and borders.
///
/// # Caveats
///
/// Since an application can not get the position of its window under
/// Wayland, calling this method only makes sense under X11.
pub fn set_root_window_bounds(&mut self, outer: Rect, inner: Rect) {
```

So the unix adapter never reads the display server. The application pushes geometry and focus in
through two methods and the adapter does the rest over D-Bus.

### 2.2 What it reads

| Input | Where | Notes |
|---|---|---|
| `AT_SPI_BUS_ADDRESS` | `adapters/unix/src/atspi/bus.rs:43` | `var("AT_SPI_BUS_ADDRESS")`. If it is unset or empty the adapter falls back to calling `BusProxy::get_address()` on the session bus (`bus.rs:45`). |
| `DBUS_SESSION_BUS_ADDRESS` | read by the `zbus` crate, not by this crate | `Builder::session()` at `adapters/unix/src/context.rs:58`. |
| The process executable name | `adapters/unix/src/context.rs:36-41` | `std::env::current_exe()`, then `path.file_name()`. This becomes `AppContext.name` (`atspi-common/src/context.rs:91`). |
| `org.a11y.Status` `IsEnabled` | `adapters/unix/src/context.rs:184-185` | Subscribed through `StatusProxy::new(&session_bus)` then `status.receive_is_enabled_changed()`. |

It reads nothing from X11, Wayland, XKB, or any window system.

### 2.3 What it caches

| Cache | Type | Where | Lifetime |
|---|---|---|---|
| `APP_CONTEXT` | `static APP_CONTEXT: OnceLock<Arc<RwLock<AppContext>>>` | `context.rs:33` | process-wide, one instance |
| `MESSAGES` | `static MESSAGES: OnceLock<Sender<Message>>` | `context.rs:34` | process-wide, one instance |
| Adapter id counter | `static NEXT_ADAPTER_ID: AtomicUsize` | `atspi-common/src/adapter.rs:352` | process-wide |
| Application tree | `AppContext.adapters: Vec<(usize, Arc<Context>)>` | `atspi-common/src/context.rs:95` | per `AppContext` |
| Per-adapter tree | `Context.tree: RwLock<Tree>` | `atspi-common/src/context.rs:37` | per adapter |
| Root window bounds | `Context.root_window_bounds: RwLock<WindowBounds>` | `atspi-common/src/context.rs:39` | per adapter |
| Desktop object reference | `Bus.desktop: Arc<OnceLock<ObjectRefOwned>>` | `adapters/unix/src/atspi/bus.rs:35` | per `Bus` |
| Live adapter list on the event thread | `adapters: Vec<AdapterEntry>` | `adapters/unix/src/context.rs:195` | per event loop |

### 2.4 How it detects changes

The adapter does not poll. It is push-driven:

- The platform sends a `TreeUpdate` through `Adapter::update_if_active`
  (`adapters/unix/src/adapter.rs:196`) or `Adapter::update_window_focus_state`
  (`adapters/unix/src/adapter.rs:222`).
- `AdapterImpl::update` (`atspi-common/src/adapter.rs:533`) creates an
  `AdapterChangeHandler` (`atspi-common/src/adapter.rs:30`), takes the tree write lock, and calls
  `tree.update_and_process_changes(update, &mut handler)` (`atspi-common/src/adapter.rs:536`).
- The handler is the diff engine. `impl TreeChangeHandler for AdapterChangeHandler`
  (`atspi-common/src/adapter.rs:280`) implements four callbacks: `node_added` (:281),
  `node_updated` (:287), `focus_moved` (:324), `node_removed` (:345).
- Text change detection is a two-ended string diff, `emit_text_change_if_needed_parent`
  (`atspi-common/src/adapter.rs:121`): it walks `old_chars` and `new_chars` in step to find the
  common prefix (`:133-146`), then walks both in reverse with `.rev().zip(...)` and
  `.take_while(...)` to find the common suffix (`:148-153`), then emits
  `ObjectEvent::TextRemoved` (`:158`) and `ObjectEvent::TextInserted` (`:172`).
- Selection change detection is deferred. `enqueue_selection_changed_if_needed`
  (`atspi-common/src/adapter.rs:260`) records the container id in `selection_changed`, and
  `emit_selection_changed` (`atspi-common/src/adapter.rs:269`) drains it after the write lock is
  dropped (`atspi-common/src/adapter.rs:538`).

The adapter also listens for one external change: the `org.a11y.Status` `IsEnabled` property,
handled by `bus_after_status_change` (`adapters/unix/src/context.rs:142`).

### 2.5 How it turns platform events into tree updates

The path runs in this order.

1. The application calls `Adapter::update_if_active` (`adapters/unix/src/adapter.rs:196`). It
   locks `self.state` (`:197`) and matches on the three-state `AdapterState`
   (`adapters/unix/src/adapter.rs:80`): `Inactive` (:81), `Pending` (:86), `Active` (:91).
2. In `Pending`, it calls `update_factory()` (:205) and constructs `AdapterImpl` through
   `AdapterImpl::with_wrapped_action_handler` (:206). The state becomes `Active` (:215).
3. `AdapterImpl::with_wrapped_action_handler` (`atspi-common/src/adapter.rs:419`) builds the
   `Tree` (:428), registers itself in the `AppContext` (:431), then calls `register_tree`
   (:437) which walks the tree and calls `register_interfaces` for every node
   (`atspi-common/src/adapter.rs:472-477`).
4. `register_interfaces` calls `self.callback.register_interfaces` (:493). The callback is
   `Callback` at `adapters/unix/src/adapter.rs:21`, whose `register_interfaces`
   (`adapters/unix/src/adapter.rs:40`) sends `Message::RegisterInterfaces { node, interfaces }`
   (:42) down the message channel.
5. On the event thread, `process_adapter_message` (`adapters/unix/src/context.rs:213`) matches
   `Message::RegisterInterfaces` (:241) and calls `bus.register_interfaces(node, interfaces)`
   (:243).
6. `Bus::register_interfaces` (`adapters/unix/src/atspi/bus.rs:120`) maps each `Interface` bit to
   a zbus interface object and calls `register_interface` (:183), which calls
   `self.conn.object_server().at(path, interface)` (:188).

Tree updates and D-Bus object export are therefore decoupled by one message channel. The
application thread never touches `zbus`.

---

## 3. The AT-SPI adapter in detail

`accesskit_atspi_common` is the translation layer. `accesskit_unix/src/atspi` is the D-Bus
binding layer. This section covers both, because the D-Bus surface is split across them.

### 3.1 Bus names, object paths and interfaces, quoted exactly

Object paths, from `adapters/unix/src/atspi/object_id.rs:14-16`:

```rust
const ACCESSIBLE_PATH_PREFIX: &str = "/org/a11y/atspi/accessible/";
const ROOT_PATH: &str = "/org/a11y/atspi/accessible/root";
const CACHE_PATH: &str = "/org/a11y/atspi/cache";
```

A node path is built at `object_id.rs:36-41` as
`format!("{}{}/{}", ACCESSIBLE_PATH_PREFIX, adapter, u128::from(*node))`.

The null object path, from `adapters/unix/src/atspi/object_address.rs:14`, with its upstream
citation at `:13`:

```rust
// https://gnome.pages.gitlab.gnome.org/at-spi2-core/libatspi/const.DBUS_PATH_NULL.html
const NULL_PATH: &str = "/org/a11y/atspi/null";
```

The interfaces, each declared by a zbus `#[interface(name = ...)]` attribute:

| D-Bus interface name | Declared at |
|---|---|
| `org.a11y.atspi.Accessible` (node) | `adapters/unix/src/atspi/interfaces/accessible.rs:33` |
| `org.a11y.atspi.Accessible` (root) | `adapters/unix/src/atspi/interfaces/accessible.rs:166` |
| `org.a11y.atspi.Application` | `adapters/unix/src/atspi/interfaces/application.rs:13` |
| `org.a11y.atspi.Cache` | `adapters/unix/src/atspi/interfaces/cache.rs:108` |
| `org.a11y.atspi.Action` | `adapters/unix/src/atspi/interfaces/action.rs:21` |
| `org.a11y.atspi.Component` | `adapters/unix/src/atspi/interfaces/component.rs:27` |
| `org.a11y.atspi.Document` | `adapters/unix/src/atspi/interfaces/document.rs:27` |
| `org.a11y.atspi.EditableText` | `adapters/unix/src/atspi/interfaces/editable_text.rs:25` |
| `org.a11y.atspi.Hyperlink` | `adapters/unix/src/atspi/interfaces/hyperlink.rs:26` |
| `org.a11y.atspi.Image` | `adapters/unix/src/atspi/interfaces/image.rs:22` |
| `org.a11y.atspi.Selection` | `adapters/unix/src/atspi/interfaces/selection.rs:26` |
| `org.a11y.atspi.Text` | `adapters/unix/src/atspi/interfaces/text.rs:25` |
| `org.a11y.atspi.Value` | `adapters/unix/src/atspi/interfaces/value.rs:23` |
| `org.a11y.atspi.Event.Object` | used as a signal interface at `adapters/unix/src/atspi/bus.rs:269` |
| `org.a11y.atspi.Event.Window` | used as a signal interface at `adapters/unix/src/atspi/bus.rs:415` |
| `org.a11y.atspi.Event.Document` | used as a signal interface at `adapters/unix/src/atspi/bus.rs:434` |
| `org.a11y.atspi.Cache` (signals) | used as a signal interface at `adapters/unix/src/atspi/bus.rs:472` |

### 3.2 Method and property names

The zbus `#[interface]` macro turns each `fn` into a D-Bus member. The source writes member names
in `snake_case`. The one place where the source overrides the name shows what the default is:
`adapters/unix/src/atspi/interfaces/hyperlink.rs:55-56` writes

```rust
    #[zbus(name = "GetURI")]
    fn get_uri(&self, index: i32) -> fdo::Result<String> {
```

The explicit override from `get_uri` to `GetURI` shows that the default conversion would
otherwise have produced `GetUri` `[INFERENCE]`, that is snake_case to UpperCamelCase. The Zig
port must emit the CamelCase name explicitly for every member, because no macro will do it.

Properties, marked with `#[zbus(property)]`:

| Interface | Property function | `path:line` |
|---|---|---|
| Accessible (node) | `name` | `accessible.rs:36` |
| Accessible (node) | `description` | `accessible.rs:41` |
| Accessible (node) | `parent` | `accessible.rs:46` |
| Accessible (node) | `child_count` | `accessible.rs:60` |
| Accessible (node) | `locale` | `accessible.rs:65` |
| Accessible (node) | `accessible_id` | `accessible.rs:70` |
| Accessible (root) | `name`, `description`, `parent`, `child_count`, `locale`, `accessible_id` | `accessible.rs:169`, `:174`, `:179`, `:189`, `:194`, `:199` |
| Application | `toolkit_name`, `version`, `atspi_version`, `id`, `set_id` | `application.rs:16`, `:21`, `:26`, `:31`, `:36` |
| Action | `n_actions` | `action.rs:24` |
| Selection | `n_selected_children` | `selection.rs:29` |
| Value | `minimum_value`, `maximum_value`, `minimum_increment`, `current_value`, `set_current_value` | `value.rs:26`, `:31`, `:36`, `:41`, `:46` |
| Image | `image_description`, `image_locale` | `image.rs:25`, `:30` |
| Hyperlink | `n_anchors`, `start_index`, `end_index` | `hyperlink.rs:29`, `:34`, `:39` |
| Document | `current_page_number`, `page_count` | `document.rs:30`, `:35` |
| Text | `character_count`, `caret_offset` | `text.rs:28`, `:33` |

Methods, in source order per interface:

| Interface | Methods, with `path:line` |
|---|---|
| Accessible (node) | `get_child_at_index` `accessible.rs:74`, `get_children` `:89`, `get_index_in_parent` `:101`, `get_relation_set` `:105`, `get_role` `:121`, `get_localized_role_name` `:125`, `get_state` `:129`, `get_attributes` `:133`, `get_application` `:137`, `get_interfaces` `:141` |
| Accessible (root) | `get_child_at_index` `accessible.rs:203`, `get_children` `:215`, `get_index_in_parent` `:223`, `get_relation_set` `:227`, `get_role` `:231`, `get_state` `:235`, `get_application` `:239`, `get_interfaces` `:243` |
| Application | `toolkit_name` `application.rs:16`, `version` `:21`, `atspi_version` `:26`, `id` `:31`, `set_id` `:36` |
| Cache | `get_items` `cache.rs:110` |
| Action | `get_description` `action.rs:28`, `get_name` `:32`, `get_localized_name` `:36`, `get_key_binding` `:40`, `get_actions` `:44`, `do_action` `:48` |
| Component | `contains` `component.rs:29`, `get_accessible_at_point` `:35`, `get_extents` `:52`, `get_layer` `:59`, `grab_focus` `:63`, `scroll_to` `:67`, `scroll_to_point` `:71` |
| Document | `get_attribute_value` `document.rs:39`, `get_attributes` `:45`, `get_locale` `:49`, `get_text_selections` `:53`, `set_text_selections` `:57` |
| EditableText | `set_text_contents` `editable_text.rs:27`, `insert_text` `:33`, `copy_text` `:37`, `cut_text` `:41`, `delete_text` `:45`, `paste_text` `:49` |
| Hyperlink | `get_object` `hyperlink.rs:43`, `get_uri` (wire name `GetURI`) `:56`, `is_valid` `:60` |
| Image | `get_image_extents` `image.rs:36`, `get_image_position` `:43`, `get_image_size` `:47` |
| Selection | `get_selected_child` `selection.rs:33`, `select_child` `:45`, `deselect_selected_child` `:51`, `is_child_selected` `:57`, `select_all` `:63`, `clear_selection` `:67`, `deselect_child` `:71` |
| Text | `get_string_at_offset` `text.rs:37`, `get_text` `:47`, `set_caret_offset` `:53`, `get_attribute_value` `:57`, `get_attributes` `:63`, `get_default_attributes` `:70`, `get_character_extents` `:76`, `get_offset_at_point` `:82`, `get_n_selections` `:88`, `get_selection` `:92`, `add_selection` `:96`, `remove_selection` `:102`, `set_selection` `:108`, `get_range_extents` `:119`, `get_attribute_run` `:130`, `scroll_substring_to` `:140`, `scroll_substring_to_point` `:151` |
| Value | `minimum_value` `value.rs:26`, `maximum_value` `:31`, `minimum_increment` `:36`, `current_value` `:41`, `set_current_value` `:46` |

### 3.3 Signal names, quoted exactly

`Bus::emit_object_event` selects the signal member from the event kind at
`adapters/unix/src/atspi/bus.rs:270-281`, with interface `"org.a11y.atspi.Event.Object"` set at
`bus.rs:269`:

| `ObjectEvent` variant | Signal member string | Line |
|---|---|---|
| `ActiveDescendantChanged` | `ActiveDescendantChanged` | `bus.rs:271` |
| `Announcement` | `Announcement` | `bus.rs:272` |
| `BoundsChanged` | `BoundsChanged` | `bus.rs:273` |
| `CaretMoved` | `TextCaretMoved` | `bus.rs:274` |
| `ChildAdded`, `ChildRemoved` | `ChildrenChanged` | `bus.rs:275` |
| `PropertyChanged` | `PropertyChange` | `bus.rs:276` |
| `SelectionChanged` | `SelectionChanged` | `bus.rs:277` |
| `StateChanged` | `StateChanged` | `bus.rs:278` |
| `TextInserted`, `TextRemoved` | `TextChanged` | `bus.rs:279` |
| `TextSelectionChanged` | `TextSelectionChanged` | `bus.rs:280` |

`Bus::emit_window_event` (`bus.rs:398`) uses interface `"org.a11y.atspi.Event.Window"`
(`bus.rs:415`) and members `Activate` (`bus.rs:410`) and `Deactivate` (`bus.rs:411`).

`Bus::emit_document_event` (`bus.rs:419`) uses interface `"org.a11y.atspi.Event.Document"`
(`bus.rs:434`) and member `LoadComplete` (`bus.rs:430`).

`Bus::emit_cache_add` (`bus.rs:441`) and `Bus::emit_cache_remove` (`bus.rs:448`) use
`emit_cache_signal` (`bus.rs:463`) with interface `"org.a11y.atspi.Cache"` (`bus.rs:472`) and
members `AddAccessible` (`bus.rs:445`) and `RemoveAccessible` (`bus.rs:460`).

`ChildrenChanged` carries a `kind` of `"add"` (`bus.rs:314`) or `"remove"` (`bus.rs:325`).
`TextChanged` carries a `kind` of `"insert"` (`bus.rs:373`) or `"delete"` (`bus.rs:385`).
`PropertyChange` carries a `kind` of `accessible-name`, `accessible-description`,
`accessible-parent`, `accessible-role` or `accessible-value` (`bus.rs:333-337`).

### 3.4 Outbound calls the adapter makes

Two proxy clients, both from the external `atspi` 0.29 crate, not from AccessKit source:

- `BusProxy`, used once: `BusProxy::new(session_bus).await?.get_address()` at
  `adapters/unix/src/atspi/bus.rs:45`. This is the `GetAddress` method on `org.a11y.Bus`.
- `SocketProxy`, used once: `SocketProxy::new(&conn)` at `bus.rs:61`, then
  `self.socket_proxy.embed(&(self.unique_name().as_str(), ObjectId::Root.path().into()))` at
  `bus.rs:88`. This is the `Embed` method on `org.a11y.atspi.Socket`.
- `StatusProxy`, used once: `StatusProxy::new(&session_bus)` at `adapters/unix/src/context.rs:184`
  and `status.receive_is_enabled_changed()` at `context.rs:185`.

### 3.5 Threading model

This is the part most likely to need a C shim, so it is set out in full.

Three threads are involved.

**Thread A, the application thread.** The caller of `Adapter::new`
(`adapters/unix/src/adapter.rs:133`), `set_root_window_bounds` (`adapter.rs:173`),
`update_if_active` (`adapter.rs:196`) and `update_window_focus_state` (`adapter.rs:222`). The doc
comment at `adapter.rs:132` states it: "All of the handlers will always be called from another
thread." In practice the activation, action and deactivation handlers are moved into the event
thread when the adapter activates, at `adapters/unix/src/context.rs:91` for activation,
`:128` and `:137` for deactivation, and reach the application through
`ActionHandlerWrapper::do_action` (`atspi-common/src/context.rs:30`), which takes a
`std::sync::Mutex` (`atspi-common/src/context.rs:21`).

**Thread B, the event loop thread.** Exactly one. It is created by `thread::spawn` inside
`get_or_init_messages` at `adapters/unix/src/context.rs:55`. The closure builds an
`Executor::new()` (`context.rs:56`), then `block_on(executor.run(async { ... }))` (`context.rs:57`).
Inside the async block it builds the session bus connection (`context.rs:58-59`) and runs
`run_event_loop` (`context.rs:61`).

**Thread C, D-Bus internals.** zbus owns its own threads, but the adapter disables zbus's own
internal executor twice: `.internal_executor(false)` at `context.rs:59` for the session bus and
again at `bus.rs:49` for the accessibility bus. It then drives zbus itself with two tick tasks,
see section 8. The result is that zbus does all of its work on thread B.

Thread B owns all D-Bus state. The `Vec<AdapterEntry>` at `context.rs:195`, the `Vec<Bus>`
connection state inside `Bus` (`bus.rs:31-36`), and the object server all live there. Thread A
only sends `Message` values through an unbounded channel.

The lock discipline is: `Adapter.state: Arc<Mutex<AdapterState>>`
(`adapters/unix/src/adapter.rs:126`) is locked on thread A at `adapter.rs:175`, `:197`, `:223`
and on thread B at `context.rs:84` and `:114`. `Context.tree: RwLock<Tree>`
(`atspi-common/src/context.rs:37`) is written on thread A under the write lock
(`atspi-common/src/adapter.rs:535`) and read on thread B through `Context.read_tree`
(`atspi-common/src/context.rs:68`).

Error handling on thread B: `zbus_error_is_unrecoverable` (`bus.rs:505`) treats only
`zbus::Error::InterfaceExists` and `zbus::Error::MissingParameter` as fatal (`bus.rs:508`).
`map_or_ignoring_recoverable_error` (`bus.rs:512`) swallows every other error and returns a
default. A fatal error panics the thread at `context.rs:63` with the message
`"Accessibility event loop failed: {error}"`.

---

## 4. The windows adapter in detail

`accesskit_windows` is a server-side UI Automation provider bound to one `HWND`. It never
consumes UIA. The only `IUIAutomation*` symbols in the crate are in the test harness
(`adapters/windows/src/tests/mod.rs:171`, `:252`, `:302`).

### 4.1 Win32 calls

| Symbol | `path:line` | Role |
|---|---|---|
| `SetWindowLongPtrW` | `adapters/windows/src/subclass.rs:111`, `:131` | install and restore the subclass window procedure |
| `GWLP_WNDPROC` | `subclass.rs:111`, `:133` | the index |
| `SetPropW` | `subclass.rs:103` | stash the subclass pointer |
| `GetPropW` | `subclass.rs:45`, `:96` | recover the pointer, and guard double install |
| `RemovePropW` | `subclass.rs:140` | clear the stash on uninstall |
| `CallWindowProcW` | `subclass.rs:73` | chain to the previous procedure |
| `IsWindowVisible` | `subclass.rs:167` | panic if the window is already shown |
| `DefWindowProcW` | `util.rs:390`, `:398` | deliberate bypass of the window to read the caption |
| `ClientToScreen` | `util.rs:380` | convert node bounds to screen space |
| `WM_GETOBJECT` | `subclass.rs:50` | the provider entry point |
| `WM_SETFOCUS`, `WM_EXITMENULOOP`, `WM_EXITSIZEMOVE` | `subclass.rs:62` | set focus state true |
| `WM_KILLFOCUS`, `WM_ENTERMENULOOP`, `WM_ENTERSIZEMOVE` | `subclass.rs:65` | set focus state false |
| `WM_NCDESTROY` | `subclass.rs:68` | mark the window destroyed |
| `WM_GETTEXTLENGTH`, `WM_GETTEXT` | `util.rs:390`, `:400` | read the window caption |
| `SafeArrayCreateVector`, `SafeArrayPutElement` | `util.rs:304`, `:310`, `:324`, `:330` | build UIA array properties |
| `LocaleNameToLCID` | `util.rs:111` | convert a locale string for `UIA_CulturePropertyId` |

There is no `SetWinEventHook`, no `UnhookWinEvent`, no `SetWindowSubclass`, and no
`CallWindowSubclassProc`.

### 4.2 UI Automation calls

Plain functions from `uiautomationcore.dll`:

| Symbol | `path:line` | Role |
|---|---|---|
| `UiaLookupId` | `adapters/windows/src/adapter.rs:599` | force UIA to initialize, per the comment at `adapter.rs:597` |
| `UiaReturnRawElementProvider` | `adapter.rs:624` | answer `WM_GETOBJECT` |
| `UiaRaiseAutomationEvent` | `adapter.rs:647` | raise a queued event |
| `UiaRaiseAutomationPropertyChangedEvent` | `adapter.rs:656` | raise a queued property change |
| `UiaAppendRuntimeId` | `adapters/windows/src/node.rs:44` | build runtime ids |
| `UiaHostProviderFromHwnd` | `node.rs:1064` | the fragment root provider |
| `UiaGetReservedMixedAttributeValue` | `util.rs:275` | the mixed text attribute value |
| `UiaGetReservedNotSupportedValue` | `text.rs:488` | the unsupported text attribute value |

Thirteen provider interfaces are implemented on one COM object, declared by
`#[implement(...)]` at `adapters/windows/src/node.rs:790-804`: `IRawElementProviderSimple`,
`IRawElementProviderFragment`, `IRawElementProviderFragmentRoot`, `IToggleProvider`,
`IInvokeProvider`, `IValueProvider`, `IRangeValueProvider`, `IScrollItemProvider`,
`ISelectionItemProvider`, `ISelectionProvider`, `ITextProvider`, `IExpandCollapseProvider`,
`IWindowProvider`. A fourteenth, `ITextRangeProvider`, is implemented on `PlatformRange`
(`adapters/windows/src/text.rs:209`).

The three hand-written base interfaces, all in `node.rs`:

| Method | `path:line` |
|---|---|
| `self.ProviderOptions()` | `node.rs:1009` |
| `self.GetPatternProvider(...)` | `node.rs:1013` |
| `self.GetPropertyValue(...)` | `node.rs:1017` |
| `self.HostRawElementProvider()` | `node.rs:1061` |
| `self.Navigate(...)` | `node.rs:1074` |
| `self.GetRuntimeId()` | `node.rs:1095` |
| `self.BoundingRectangle()` | `node.rs:1110` |
| `self.GetEmbeddedFragmentRoots()` | `node.rs:1125` |
| `self.SetFocus()` | `node.rs:1129` |
| `self.FragmentRoot()` | `node.rs:1133` |
| `self.ElementProviderFromPoint(...)` | `node.rs:1149` |
| `self.GetFocus()` | `node.rs:1165` |

The pattern providers are generated by a Rust macro, `patterns!`, declared at `node.rs:1245` and
invoked at `node.rs:1332-1531`. Each generated method is a COM vtable entry. The property getter
machinery comes from a second macro, `properties!`, declared at `node.rs:1183`.

### 4.3 The subclassing mechanism

The subclass proc is installed by replacing `GWLP_WNDPROC`:

```rust
// adapters/windows/src/subclass.rs:111
unsafe { SetWindowLongPtrW(self.hwnd, GWLP_WNDPROC, wnd_proc as *const c_void as _) };
```

The back pointer is a window property, not `GWLP_USERDATA`. The name is
`adapters/windows/src/subclass.rs:30`:

```rust
const PROP_NAME: PCWSTR = w!("AccessKitAdapter");
```

State lives in `struct SubclassImpl`, `adapters/windows/src/subclass.rs:37-42`, with fields
`hwnd: HWND` (`:38`), `state: RefCell<SubclassState>` (`:39`), `prev_wnd_proc: WNDPROC` (`:40`)
and `window_destroyed: Cell<bool>` (`:41`). `SubclassState` (`:32-35`) holds `adapter: Adapter`
(`:33`) and `activation_handler: Box<dyn ActivationHandler>` (`:34`).

The lifetime is the `Box` inside `SubclassingAdapter(Box<SubclassImpl>)`
(`adapters/windows/src/subclass.rs:148`). `Drop for SubclassingAdapter` (`:200`) calls
`uninstall` (`:126`), which returns early if `WM_NCDESTROY` already fired (`:127`), restores the
previous proc (`:130-136`), then calls `RemovePropW` (`:140`).

The critical invariant is documented in the source at
`adapters/windows/src/adapter.rs:527-533` and `:633-637`: raising UIA events can re-enter
`WM_GETOBJECT`, which re-borrows the same `RefCell`. The code therefore drops the borrow first at
`adapters/windows/src/subclass.rs:58` and `:121`.

### 4.4 Threading model

COM is never initialised. There is no `CoInitializeEx` or `CoInitialize` in `src/`. Instead
`init_uia` (`adapters/windows/src/adapter.rs:596`) calls `UiaLookupId` (`:599`) once, at adapter
construction. The reason is stated at `adapter.rs:416-422`: `Adapter::new` must not run while
handling `WM_GETOBJECT`, because UIA must be initialised before that message is handled, to
avoid a race that produces nested `WM_GETOBJECT` messages.

Three thread roles:

- **Window thread.** Runs the subclass proc and every UIA callback for this window. It also runs
  the activation handler inline: `adapters/windows/src/subclass.rs:53-57` calls
  `adapter.handle_wm_getobject`, which calls `activation_handler.request_initial_tree()` at
  `adapter.rs:554`. The doc at `adapters/windows/src/subclass.rs:155-157` states the activation
  handler always runs on the thread that owns the window.
- **Any thread.** Tree mutation. `update_if_active` (`adapter.rs:463`) and
  `update_window_focus_state` (`adapter.rs:500`) are documented "may be safely called on any
  thread" (`adapter.rs:460`, `:497`) and take `context.tree.write()` at `adapter.rs:472`, `:484`,
  `:510`, `:516`. The mutating thread only builds `Vec<QueuedEvent>` and returns it; the caller
  must call `QueuedEvents::raise` (`adapter.rs:643`).
- **UIA client thread.** Any thread UIA chooses. Callbacks must be safe there. The string
  scratch pool is `thread_local!` (`adapters/windows/src/util.rs:28-30`), so concurrent
  callbacks never share a buffer.

There is no message filter and no message pump in the adapter. There is no `IOleMessageFilter`,
no `OleRegisterMessageFilter`, no `GetMessage`, `PeekMessage`, `DispatchMessage`, `SendMessage`
or `PostMessage` in `src/`.

### 4.5 `text.rs` in detail

`text.rs` is 652 lines. It implements one COM object, `PlatformRange`, which is a provider-side
`ITextRangeProvider`:

```rust
// adapters/windows/src/text.rs:209-213
#[implement(ITextRangeProvider)]
pub(crate) struct PlatformRange {
    context: Weak<Context>,
    state: RwLock<WeakRange>,
}
```

`WeakRange` is `accesskit_consumer::WeakTextRange`, aliased at `text.rs:11`. `Range` is
`accesskit_consumer::TextRange` and `Position` is `accesskit_consumer::TextPosition`, aliased at
`text.rs:10`. The range is stored detached from the tree; every method re-acquires the tree read
lock (`text.rs:227`) and upgrades the weak range (`text.rs:24`).

All eighteen `ITextRangeProvider` methods, with `path:line`:

| Method | Line | Behaviour where it differs from the obvious |
|---|---|---|
| `self.Clone()` | `text.rs:321` | |
| `self.Compare(...)` | `text.rs:325` | compares context pointer and weak range; takes no tree lock |
| `self.CompareEndpoints(...)` | `text.rs:332` | fast path on `start_comparable()`/`end_comparable()` (`:339-350`), no upgrade |
| `self.ExpandToEnclosingUnit(...)` | `text.rs:365` | `TextUnit_Document` handled before the upgrade (`:366-376`) so a stale range still works |
| `self.FindAttribute(...)` | `text.rs:396` | unimplemented |
| `self.FindText(...)` | `text.rs:407` | unimplemented |
| `self.GetAttributeValue(...)` | `text.rs:419` | 17 attribute ids mapped, the rest return `UiaGetReservedNotSupportedValue()` (`:488`) |
| `self.GetBoundingRectangles()` | `text.rs:494` | flat `x, y, w, h` array through `safe_array_from_f64_slice` |
| `self.GetEnclosingElement()` | `text.rs:512` | |
| `self.GetText(...)` | `text.rs:520` | `_max_length` deliberately ignored (`:521-522`) |
| `self.Move(...)` | `text.rs:531` | collapses to a caret if degenerate |
| `self.MoveEndpointByUnit(...)` | `text.rs:554` | |
| `self.MoveEndpointByRange(...)` | `text.rs:569` | |
| `self.Select()` | `text.rs:594` | emits `Action::SetTextSelection` |
| `self.AddToSelection()` | `text.rs:606` | `Err(invalid_operation())`, no multi-select |
| `self.RemoveFromSelection()` | `text.rs:611` | `Err(invalid_operation())` |
| `self.ScrollIntoView(...)` | `text.rs:616` | `ScrollHint::TopEdge` or `BottomEdge` |
| `self.GetChildren()` | `text.rs:640` | `safe_array_from_com_slice(&[])` |

**Offsets are not converted to UTF-16.** The brief asked how `text.rs` converts character offsets
to UTF-16 offsets. It does not. Positions are `TextPosition` values, that is node id plus
intra-node offset, compared with `partial_cmp` at `text.rs:360`. `Move`'s `count` at
`text.rs:174-207` is a count of text units, not of UTF-16 code units. `MoveEndpointByRange`
copies a whole position (`text.rs:587-588`), never an integer index. The only UTF-16 conversion
in the adapter is one-way, `&str` to `&[u16]`, and it is in `util.rs`:
`self.0.extend(s.encode_utf16())` at `util.rs:84`, `c.encode_utf16(&mut [0; 2])` at `util.rs:89`,
and `BSTR::from_wide` at `util.rs:102` and `:410`.

Text-unit navigation is delegated to `accesskit_consumer`: `forward_to_character_start()` at
`text.rs:137`, `backward_to_word_start()` at `:165`, `forward_to_paragraph_end()` at `:154`,
`backward_to_format_start()` at `:164`, `document_start()` and `document_end()` at `:128`, `:143`,
`:156`, `:169`.

Two casts in this file are unchecked. `as_impl()` at `text.rs:326`, `:338` and `:575` casts a
`Ref<ITextRangeProvider>` back to the concrete implementation. The source justifies this at
`text.rs:314-317` with the comment "We assume that AccessKit is the only UIA provider within this
process." A Zig port must carry the same assumption, and should say so in a comment, because
Zig has no borrow checker to catch the failure.

---

## 5. The macOS, iOS and Android adapters

### 5.1 macOS

**Native API surface.** Two plain C functions in the Accessibility framework:
`NSAccessibilityPostNotification`, used at `adapters/macos/src/context.rs:96` and
`adapters/macos/src/event.rs:53` and `:58`; and
`NSAccessibilityPostNotificationWithUserInfo` at `adapters/macos/src/event.rs:97`.

Notification name constants, all typed `&'static NSAccessibilityNotificationName` at
`adapters/macos/src/event.rs:25`, never string literals:
`NSAccessibilityUIElementDestroyedNotification` (`context.rs:98`, `event.rs:60`),
`NSAccessibilityFocusedUIElementChangedNotification` (`event.rs:136`),
`NSAccessibilityValueChangedNotification` (`event.rs:189`, `:281`, `:287`),
`NSAccessibilitySelectedRowsChangedNotification` (`event.rs:211`),
`NSAccessibilityTitleChangedNotification` (`event.rs:267`),
`NSAccessibilitySelectedTextChangedNotification` (`event.rs:297`),
`NSAccessibilityAnnouncementRequestedNotification` (`event.rs:99`).
User-info keys: `NSAccessibilityAnnouncementKey` (`event.rs:85`),
`NSAccessibilityPriorityKey` (`event.rs:92`). Priority levels
`NSAccessibilityPriorityHigh` (`event.rs:39`) and `NSAccessibilityPriorityMedium`
(`event.rs:41`).

Objective-C runtime calls, from the `objc2` crate:
`objc_getAssociatedObject` (`subclass.rs:77`, `:151`),
`objc_setAssociatedObject` (`subclass.rs:164`, `:265`),
`OBJC_ASSOCIATION_RETAIN_NONATOMIC` (`subclass.rs:12`, `:168`, `:269`),
`object_setClass` (`subclass.rs:203`, `:263`), and
`class_addMethod` (`adapters/macos/src/patch.rs:71`).
`objc_msgSend` is never spelled; it sits behind `msg_send!`.

**What it must do that the others do not.** It must map the AccessKit `Role` enum onto the
`NSAccessibilityRole` constant. The table is `ns_role` at
`adapters/macos/src/node.rs:36-231` and covers 30 roles with named constants such as
`NSAccessibilityStaticTextRole` (`node.rs:44`) plus six literal role strings: `"AXListMarker"`
(`node.rs:49`), `"AXDateField"` (`node.rs:86`), `"AXTimeField"` (`node.rs:88`), `"Heading"`
(`node.rs:125`), `"AXWebArea"` (`node.rs:149`), `"AXHeading"` (`node.rs:224`). It must also map
onto `NSAccessibilitySubrole`; `ns_sub_role` at `node.rs:244-296` carries seven named subroles
such as `NSAccessibilityDialogSubrole` (`node.rs:250`) and 28 literal subrole strings such as
`"AXDocument"` (`node.rs:262`). It must implement the full AppKit rich-text protocol:
`accessibilityNumberOfCharacters` (`node.rs:755`), `accessibilitySelectedText` (`node.rs:767`),
`accessibilitySelectedTextRange` (`node.rs:781`),
`accessibilityInsertionPointLineNumber` (`node.rs:794`), `accessibilityRangeForLine:`
(`node.rs:807`), `accessibilityRangeForPosition:` (`node.rs:820`),
`accessibilityStringForRange:` (`node.rs:840`), `accessibilityAttributedStringForRange:`
(`node.rs:854`), `accessibilityFrameForRange:` (`node.rs:960`), `accessibilityLineForIndex:`
(`node.rs:985`), `accessibilityRangeForIndex:` (`node.rs:998`),
`accessibilityStyleRangeForIndex:` (`node.rs:1011`), and `setAccessibilitySelectedTextRange:`
(`node.rs:1031`). None of this exists on iOS. It must also implement the table API:
`accessibilityRows` (`node.rs:1106`), `accessibilitySelectedRows` (`node.rs:1122`),
`accessibilityPerformPick` (`node.rs:1139`). And it must ship `patch.rs`, which adds one method
to a caller-named `NSWindow` subclass.

**`patch.rs`, 93 lines.** `focus_forwarder` (`patch.rs:17`) is an `extern "C"` function that
calls `this.contentView()` (`patch.rs:19`) then sends `accessibilityFocusedUIElement`
(`patch.rs:20`). `add_focus_forwarder_to_window_class` (`patch.rs:39`) looks the class up
(`:40`) and calls a vendored `add_method` (`:53-79`) which builds a type-encoding string
(`:69`) and calls `class_addMethod` (`patch.rs:71`). Helpers `count_args` (`patch.rs:81`) and
`method_type_encoding` (`patch.rs:85`). The operation is irreversible and the doc comment at
`patch.rs:31-38` says the crate must never be unloaded once it has run.

This vendored `add_method` is the most useful single artifact in the Apple adapters. It is a
complete, self-contained `class_addMethod` wrapper including type-encoding construction and the
selector-arity assertion. A Zig port can reuse this exact strategy for every dynamically
declared class and can then delete `declare_class!`, `#[method]`, `Encode`, `RefEncode`,
`ClassType` and `DeclaredClass` entirely.

**Subclassing.** Three parts, no swizzling. A class cache
`static SUBCLASSES: Mutex<Vec<(&'static AnyClass, &'static AnyClass)>>` at
`adapters/macos/src/subclass.rs:27`. An associated object holding state, key derived from the
address of `static ASSOCIATED_OBJECT_KEY: u8` at `subclass.rs:29`, read at `:77` and written at
`:164`. A per-instance state class declared at `subclass.rs:45` with runtime name
`"AccessKitSubclassAssociatedObject"` (`subclass.rs:51`), ivars `AssociatedObjectIvars` at
`subclass.rs:40-43`. Four trampolines: `superclass` (`subclass.rs:87`) for `sel!(superclass)`,
`children` (`:92`) for `sel!(accessibilityChildren)`, `focus` (`:101`) for
`sel!(accessibilityFocusedUIElement)`, and `hit_test` (`:108`) for
`sel!(accessibilityHitTest:)`. The subclass class name is
`format!("AccessKitSubclassOf{}", prev_class.name())` (`subclass.rs:175`). `Drop` reverts the
class and clears the association (`subclass.rs:259-273`).

**Threading model.** Main thread only, enforced by `MainThreadMarker::new().unwrap()` at
`adapters/macos/src/adapter.rs:96`. There is no `dispatch_queue`, no `NSRunLoop`, no
`NSNotificationCenter` observation, no run loop, and no main queue anywhere in the crate
`[INFERENCE, verified by grep]`. The event model is push-only: `EventGenerator` implements
`accesskit_consumer::TreeChangeHandler` at `adapters/macos/src/event.rs:227`, and
`QueuedEvents::raise` (`event.rs:126-130`) posts synchronously. Note the ordering-sensitive
`events.insert(0, ...)` at `event.rs:174-193`, which prepends text-change events so they land
before the events already queued for the same node.

### 5.2 iOS

**Native API surface.** One plain C function: `UIAccessibilityPostNotification` at
`adapters/ios/src/event.rs:57`. One hand-written `extern "C"` block in the whole crate, at
`adapters/ios/src/util.rs:73-75`:

```rust
const RTLD_DEFAULT: *mut c_void = -2isize as *mut c_void;

unsafe extern "C" {
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
}
```

`dlsym` is used to resolve constants that are weak-linked at runtime:
`"UIAccessibilityTraitToggleButton"` (`util.rs:77-87`),
`"UIAccessibilityPriorityHigh"` (`util.rs:100`),
`"UIAccessibilityPriorityLow"` (`util.rs:104`), and
`"UIAccessibilitySpeechAttributeAnnouncementPriority"` (`util.rs:108`). This is rung 1 in Zig:
`std.DynLib` already provides `open`, `lookup`, and `close`, so the `extern "C"` block and the
`-2` sentinel both disappear.

Notification observation. `observed_notification_names` at
`adapters/ios/src/adapter.rs:105-119` returns nine names, typed
`&'static NSNotificationName`:
`UIAccessibilityVoiceOverStatusDidChangeNotification`,
`UIAccessibilitySwitchControlStatusDidChangeNotification`,
`UIAccessibilitySpeakScreenStatusDidChangeNotification`,
`UIAccessibilityInvertColorsStatusDidChangeNotification`,
`UIAccessibilityReduceMotionStatusDidChangeNotification`,
`UIAccessibilityBoldTextStatusDidChangeNotification`,
`UIAccessibilityDarkerSystemColorsStatusDidChangeNotification`,
`UIAccessibilityOnOffSwitchLabelsStatusDidChangeNotification` as spelled in the source, and
`UIAccessibilityVideoAutoplayStatusDidChangeNotification`.
`any_assistive_tech_running` (`adapter.rs:97-103`) calls `UIAccessibilityIsVoiceOverRunning`,
`UIAccessibilityIsSwitchControlRunning` and `UIAccessibilityIsSpeakScreenEnabled`.
Registration happens at `adapter.rs:370-380` through
`NSNotificationCenter::defaultCenter` plus `addObserver:selector:name:object:`. The observer is
a dynamically declared class, `declare_class!` at `adapter.rs:245`, runtime name
`"AccessKitAccessibilityStatusObserver"` (`adapter.rs:245`), with the single method
`#[method(accessibilityStatusChanged:)]` at `adapter.rs:259`. `Drop for Adapter` removes the
observer at `adapter.rs:506`.

**What it must do that macOS does not.** It must observe the nine status notifications above, so
that the adapter activates and deactivates as assistive technology comes and goes. macOS does
none of this; macOS is push-only. It must implement the `DeactivationHandler`; macOS takes only
an `ActionHandler` and stores the `ActivationHandler` per call (`adapters/macos/src/adapter.rs:89-104`),
while iOS takes both at construction (`adapters/ios/src/adapter.rs:344`). It must handle the view
lifecycle: `didMoveToWindow` is hooked at `adapters/ios/src/subclass.rs:116` and chains to
super first (`subclass.rs:122`), then calls `view_did_appear` (`adapter.rs:444`);
`new_internal` catches up manually when the view is already in a window
(`subclass.rs:249-253`). It must maintain `platform_focus: RefCell<Option<FullNodeId>>` at
`adapters/ios/src/context.rs:40`. It must implement a structural filter,
`filter_for_is_accessibility_element` (`adapters/ios/src/filters.rs:27-52`), which macOS does not
have; macOS instead gates per selector with `isAccessibilitySelectorAllowed:`
(`adapters/macos/src/node.rs:1234-1329`). It must map `Role` onto `UIAccessibilityTraits`
(`adapters/ios/src/node.rs:124-165`) and onto `UIAccessibilityContainerType`
(`node.rs:167-188`); macOS has no traits bitmask and no subrole table at all. It must implement
`accessibilityScroll:` with an inverted vertical mapping (`node.rs:359-391`); macOS has no
scroll support. It must implement `accessibilityActivate` (`node.rs:303`) where macOS
implements `accessibilityPerformPress` (`adapters/macos/src/node.rs:693`), and void-returning
`accessibilityIncrement`/`accessibilityDecrement` (`adapters/ios/src/node.rs:323`, `:341`)
where macOS returns `bool` (`adapters/macos/src/node.rs:712`, `:731`).

**Subclassing.** Same associated-object plus ISA-swap mechanism as macOS, but `MainThreadOnly`
(`adapters/ios/src/subclass.rs:45`) and the `Adapter` itself stored directly in
`AssociatedObjectIvars` (`subclass.rs:35-38`) with no `RefCell` and no activation handler. Five
trampolines: `superclass` (`subclass.rs:80`), `is_accessibility_element` (`:87`),
`accessibility_elements` (`:94`), `accessibility_hit_test` (`:103`), and `did_move_to_window`
(`:116`). The window entry point is `rootViewController().view()` (`subclass.rs:270-289`), where
macOS uses `-[NSWindow contentView]` (`adapters/macos/src/subclass.rs:229`).

**Threading model and re-entrancy.** Main thread, enforced by
`MainThreadMarker::new().unwrap()` at `adapters/ios/src/adapter.rs:352` and
`subclass.rs:176`. The adapter holds `Rc<RefCell<State>>` (`adapter.rs:320`) rather than using
`&mut self`, because callbacks can fire re-entrantly while the caller holds `&self`. The
discipline is documented verbatim at `adapters/ios/src/adapter.rs:124-127` and implemented by
releasing the borrow at `adapter.rs:146`, calling the handler at `:148`, re-borrowing at `:150`,
and preferring any state a re-entrant path already installed (`:152-156`). A Zig port must
reproduce this exactly. A two-phase match on a plain `state` field, without any borrow flag,
is enough `[INFERENCE]`.

### 5.3 Android

**Native API surface.** The adapter is pure JNI through the `jni` 0.21.1 crate
(`adapters/android/Cargo.toml:21`). There is no `ndk` crate, no C source in the library, no JNI
header, no `ANativeWindow*` symbol, and no `Java_`-prefixed export anywhere in the crate
`[INFERENCE, verified by grep]`. The only `#[link(name = "log")]` is in the example
`adapters/android/examples/hello_world.rs:132`, which is not the adapter.

Five native functions are bound with `RegisterNatives`, not by name mangling. The binding table
is at `adapters/android/src/inject.rs:257-291`:

| Java name, quoted exactly | JNI signature, quoted exactly | Rust function | `path:line` |
|---|---|---|---|
| `runCallback` | `(Landroid/view/View;J)V` | `run_callback` | `inject.rs:137`, registered `:261-264` |
| `createAccessibilityNodeInfo` | `(JLandroid/view/View;I)Landroid/view/accessibility/AccessibilityNodeInfo;` | `create_accessibility_node_info` | `inject.rs:149`, registered `:265-270` |
| `findFocus` | `(JLandroid/view/View;I)Landroid/view/accessibility/AccessibilityNodeInfo;` | `find_focus` | `inject.rs:163`, registered `:272-277` |
| `performAction` | `(JLandroid/view/View;IILandroid/os/Bundle;)Z` | `perform_action` | `inject.rs:177`, registered `:279-283` |
| `onHoverEvent` | `(JLandroid/view/View;IFF)Z` | `on_hover_event` | `inject.rs:201`, registered `:284-288` |

The Java class is `dev.accesskit.android.Delegate`, loaded two ways. Without the
`embedded-dex` feature, `env.find_class("dev/accesskit/android/Delegate")` at
`adapters/android/src/inject.rs:256`. With the feature, the adapter builds a
`dalvik/system/InMemoryDexClassLoader` (`inject.rs:228`), wraps the embedded
`include_bytes!("../classes.dex")` (`inject.rs:230`), and loads the class name string
`"dev.accesskit.android.Delegate"` (`inject.rs:242`) through `loadClass` (`inject.rs:245`).

The Java-side methods that carry the name, from
`adapters/android/java/dev/accesskit/android/Delegate.java`: `runCallback(View,long)` (`:22`),
`createAccessibilityNodeInfo(long,View,int)` (`:24`), `findFocus(long,View,int)` (`:27`),
`performAction(long,View,int,int,Bundle)` (`:30`), `onHoverEvent(long,View,int,float,float)`
(`:33`), and the static factory `newCallback(View,long)` (`:36`) returning a `Runnable` whose
`run()` calls `runCallback(host, handle)` (`:40`).

Injection calls back into Java by exact name: `getAccessibilityDelegate` with descriptor
`()Landroid/view/View$AccessibilityDelegate;` (`inject.rs:354`),
`setAccessibilityDelegate` with `(Landroid/view/View$AccessibilityDelegate;)V` (`:369`),
`setOnHoverListener` with `(Landroid/view/View$OnHoverListener;)V` (`:376`), and `post` with
`(Ljava/lang/Runnable;)Z` (`:130`). The static factory is called by name `"newCallback"` with
descriptor `"(Landroid/view/View;J)Ljava/lang/Runnable;"` (`inject.rs:121-122`).

**What it must do that the others do not.** It must speak the Android accessibility framework
rather than a desktop one. `NodeWrapper::populate_node_info`
(`adapters/android/src/node.rs:196`) fills an `AccessibilityNodeInfo`, including bounds via
`getLocationOnScreen` plus `android.graphics.Rect` (`node.rs:233-258`), about twenty setters,
the extras key `"AccessibilityNodeInfo.targetUrl"` (`node.rs:348`), and the action list
(`node.rs:372-405`). `class_name` (`node.rs:124-170`) maps `Role` onto concrete Android widget
class-name strings. `QueuedEvents::raise` (`adapters/android/src/event.rs:347`) builds
`android.view.accessibility.AccessibilityEvent` objects and sends them through
`ViewParent.requestSendAccessibilityEvent` (`event.rs:52`). `PlatformAction::from_java`
(`adapters/android/src/action.rs:36`) parses the incoming `Bundle` using the framework argument
keys `ACTION_ARGUMENT_SELECTION_START_INT` and `ACTION_ARGUMENT_SELECTION_END_INT`
(`action.rs`), `ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT` with
ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN`, and
`android.view.accessibility.action.ARGUMENT_PROGRESS_VALUE` (`action.rs`).

It must also manage Java object lifetimes from a native cache. `NEXT_HANDLE` and `HANDLE_MAP`
(`inject.rs:88`, `:89`) map a `jlong` to a `Weak<Mutex<InnerInjectingAdapter>>`;
`NEXT_CALLBACK_HANDLE` and `CALLBACK_MAP` (`inject.rs:101`, `:103`) map a `jlong` to a boxed
closure. The host view is held as a `WeakRef` (`inject.rs:311`), so the adapter does not keep the
view alive.

**Threading model.** Three threads. The Java UI thread, where the framework calls the five
native methods. The application thread, from which `InjectingAdapter::update_if_active`
(`inject.rs:402`) may be called; its doc at `inject.rs:398-401` states the method may be called
from any thread and attaches to the JVM for the duration of the call if needed. And the
framework thread that runs the posted `Runnable`. `attach_and_post_to_ui_thread`
(`inject.rs:418`) calls `self.vm.attach_current_thread()` (`inject.rs:422`), opens a JNI local
frame with `LOCAL_FRAME_CAPACITY = 2` (`inject.rs:99`, `:423`), upgrades the weak host reference
(`:424`), and posts (`inject.rs:427`). Every `QueuedEvent` dispatch ends with
`host.invalidate()` for the `InvalidateHost` variant (`adapters/android/src/event.rs:414`).

**The dex problem.** `adapters/android/build-dex.sh` runs `javac` and `d8` and produces
`adapters/android/classes.dex`, which the crate embeds with `include_bytes!`
(`adapters/android/src/inject.rs:230`). That is a checked-in build artifact generated by a
Rust-adjacent shell script. Under the no-Rust-toolchain rule this cannot stay as a silent blob
with no reproducibility path. Two honest options exist. Option A: check in the 70 lines of
`Delegate.java` and have the Zig build invoke `javac` and `d8` as ordinary build steps, which
makes the artifact reproducible from this repository alone. Option B: check in `classes.dex`
and check in `build-dex.sh` side by side, and add a test that compares the embedded bytes against
the output of a fresh `d8` run. `[INFERENCE]` The port should take option A, because the house
rule against non-reproducible generated files applies directly.

---

## 6. The winit integration

### 6.1 What a toolkit integration adds over a platform adapter

`adapters/winit/src/lib.rs` is 267 lines. It adds exactly two things.

**First, three ways to supply handlers.** `Adapter::with_event_loop_proxy`
(`adapters/winit/src/lib.rs:149`) sends every AccessKit request through a winit
`EventLoopProxy`, using the three private wrapper types `WinitActivationHandler`
(`lib.rs:81`), `WinitActionHandler` (`lib.rs:97`) and `WinitDeactivationHandler` (`lib.rs:112`).
`Adapter::with_direct_handlers` (`lib.rs:190`) calls the application directly.
`Adapter::with_mixed_handlers` (`lib.rs:229`) uses a direct activation handler and a proxy for
the other two. The reason for the split is documented at `lib.rs:137-144`: a proxy cannot return
an initial tree synchronously, so some platform adapters need a placeholder tree until the first
update.

**Second, translation of toolkit events into adapter calls.** `Adapter::process_event`
(`lib.rs:254`) forwards to `self.inner.process_event`, and each platform does something
different:

| Platform | What `process_event` does | `path:line` |
|---|---|---|
| unix | `WindowEvent::Moved` and `WindowEvent::Resized` become `set_root_window_bounds`; `WindowEvent::Focused` becomes `update_window_focus_state`; everything else is ignored | `adapters/winit/src/platform_impl/unix.rs:37`, `:39`, `:53`, `:71`, `:74` |
| macOS | only `WindowEvent::Focused`, which calls `update_view_focus_state` then `events.raise()` | `adapters/winit/src/platform_impl/macos.rs:48`, `:49-51` |
| windows | nothing | `adapters/winit/src/platform_impl/windows.rs:48` |
| ios | nothing | `adapters/winit/src/platform_impl/ios.rs:54` |
| android | nothing | `adapters/winit/src/platform_impl/android.rs:48` |
| none | nothing; `pub struct Adapter;` is a unit struct whose `new` returns `Self {}` | `adapters/winit/src/platform_impl/null.rs:8`, `:18` |

The `null.rs` fallback is selected by a long `#[cfg(not(any(...)))]` at
`adapters/winit/src/platform_impl/mod.rs:38-55`.

There is no extension trait. The public API is the struct `Adapter` (`lib.rs:127`), the two
constructors at `:149` and `:190` and `:229`, `process_event` (`:254`) and `update_if_active`
(`:264`).

### 6.2 Does the port need it

**Recommendation: no. Do not port `accesskit_winit`.** Reason: winit is a Rust crate with no
Zig equivalent that the port could bind to, and the port must build with no Rust. Reproducing
it would mean writing a winit clone, which is a different project.

The functionality it adds is small and belongs in the application, not in the library:

1. Handler plumbing. The unix adapter already takes the three handlers at construction,
   `adapters/unix/src/adapter.rs:133-137`. The proxy variant exists only to hop threads for
   convenience.
2. Focus and geometry. The unix adapter exposes `set_root_window_bounds`
   (`adapters/unix/src/adapter.rs:173`) and `update_window_focus_state`
   (`adapters/unix/src/adapter.rs:222`). The application calls them. The winit code at
   `adapters/winit/src/platform_impl/unix.rs:39` is 40 lines of coordinate copying that the
   application can do directly from its own window events.

The port instead defines a small `Adapter` struct per platform with the same four methods that
`adapters/winit/src/lib.rs` exposes to its callers: construction, `update_ifActive`,
`updateWindowFocusState` where the platform needs it, and the platform-specific entry points.
Document this decision in `docs/30-port-design.md` so it is not re-litigated.

---

## 7. The executor, line by line

`adapters/unix/src/executor.rs` is 158 lines. The task brief called it "the scheduling core".
That is accurate, but only for one thread, and the file itself says it was copied:
`adapters/unix/src/executor.rs:6-8` reads
`// Derived from zbus.` with a Zeeshan Ali Khan MIT licence header.

### 7.1 Line-by-line

| Lines | Content |
|---|---|
| 1-4 | Apache-2.0-or-MIT licence header. |
| 6-8 | Provenance note: derived from zbus. |
| 10 | `#[cfg(not(feature = "tokio"))]` guard on the next import. |
| 11 | `use async_executor::Executor as AsyncExecutor;` |
| 12-13 | `use async_task::Task as AsyncTask;` under the same guard. |
| 14-15 | `use std::marker::PhantomData;` under `tokio`. |
| 16-17 | `use std::sync::Arc;` when not `tokio`. |
| 18-22 | `use std::{ future::Future, pin::Pin, task::{Context, Poll} };` |
| 23-24 | `use tokio::task::JoinHandle;` under `tokio`. |
| 26-32 | Doc comment: the type exists so the crate can sit on any runtime. |
| 33-37 | `#[cfg(not(feature = "tokio"))] pub(crate) struct Executor<'a> { executor: Arc<AsyncExecutor<'a>> }`. |
| 38-42 | `#[cfg(feature = "tokio")] pub(crate) struct Executor<'a> { phantom: PhantomData<&'a ()> }`. Under tokio the type is empty. |
| 44 | `impl Executor<'_> {` |
| 46-60 | `pub(crate) fn spawn<T: Send + 'static>(&self, future: impl Future<Output = T> + Send + 'static, #[allow(unused)] name: &str) -> Task<T>`. Body: `Task(Some(self.executor.spawn(future)))` at `:53`, or `Task(Some(tokio::task::spawn(future)))` at `:58`. |
| 62-77 | `pub(crate) fn new() -> Self`. Body: `Self { executor: Arc::new(AsyncExecutor::new()) }` at `:67`, or the phantom form at `:74`. |
| 79-91 | `pub(crate) async fn run<T>(&self, future: impl Future<Output = T>) -> T`. Body: `self.executor.run(future).await` at `:85`, or a plain `future.await` at `:89`. |
| 92 | `}` closes the impl. |
| 94-100 | Doc comment recording the drop semantics: the task is cancelled, not detached; to detach, call `detach`. |
| 101-103 | `#[cfg(not(feature = "tokio"))] pub(crate) struct Task<T>(Option<AsyncTask<T>>);` |
| 104-106 | `#[cfg(feature = "tokio")] pub(crate) struct Task<T>(Option<JoinHandle<T>>);` |
| 108 | `impl<T> Task<T> {` |
| 112-122 | `pub(crate) fn detach(mut self)`. Body at `:115`: `self.0.take().expect("async_task::Task is none").detach()`. |
| 123 | `}` |
| 125-134 | `impl<T> Drop for Task<T>`. Under `tokio` only: `join_handle.abort()` at `:130`. Under `async-executor` the drop is empty, because `async_task::Task` cancels on drop by itself. |
| 136-158 | `impl<T> Future for Task<T>`. `fn poll` at `:139`. Body at `:142`: `Pin::new(&mut self.get_mut().0.as_mut().expect(...)).poll(cx)`, or at `:147-155` the tokio form mapping the join error through `expect("tokio::task::JoinHandle error")`. |

The `name: &str` parameter at `:49` is marked `#[allow(unused)]` and is only used by zbus for
diagnostics. A Zig port should drop it.

### 7.2 What work is dispatched, on which thread, in what order

**Threads.** Two. Thread A is the application thread. Thread B is the single thread created by
`thread::spawn` at `adapters/unix/src/context.rs:55`.

The `async-io` path uses `async_executor::Executor::new()`
(`adapters/unix/src/executor.rs:67`), which is a single-threaded executor. Every task spawned
through `Executor::spawn` therefore runs on thread B, because thread B is the only thread ever
calling `Executor::run` (`executor.rs:85`). This is the whole scheduling story. There is no work
stealing and no task pool.

**Order of dispatch on thread B.**

1. `Executor::new()` at `context.rs:56`.
2. `block_on(executor.run(async { ... }))` at `context.rs:57`. This is what makes thread B an
   event loop: the executor runs the outer future, and re-entrantly runs any spawned task that
   becomes ready.
3. `Builder::session()` at `context.rs:58`, then
   `session_bus.internal_executor(false).build().await` at `context.rs:59`. The
   `.internal_executor(false)` call tells zbus not to start its own executor thread, so all
   session-bus work is driven by the loop.
4. `run_event_loop(&executor, session_bus, rx).await` at `context.rs:61`.
5. Inside `run_event_loop` (`context.rs:169`), the first task is spawned: the session-bus tick
   loop, named `"accesskit_session_bus_task"` (`context.rs:175-182`). Its body is
   `loop { session_bus_copy.executor().tick().await; }` (`context.rs:177-179`).
6. `StatusProxy::new(&session_bus)` at `context.rs:184`, then
   `status.receive_is_enabled_changed()` at `context.rs:185`, then `.fuse()` and `pin!` at
   `context.rs:186`.
7. The message stream is fused and pinned at `context.rs:188-192`.
8. The `select!` loop at `context.rs:197-210`. Two branches: the `IsEnabled` change stream
   (`:199`) and the message stream (`:204`).
9. When `IsEnabled` turns true, `bus_after_status_change` (`context.rs:142`) calls
   `Bus::new(session_bus, executor)` (`context.rs:152`), which spawns a second tick task named
   `"accesskit_atspi_bus_task"` (`adapters/unix/src/atspi/bus.rs:53-60`), then calls
   `SocketProxy::new(&conn)` (`bus.rs:61`), then `register_root_node` (`bus.rs:68`), which
   exports `ApplicationInterface` at `ObjectId::Root.path()` (`bus.rs:83`), calls
   `self.socket_proxy.embed(...)` (`bus.rs:88`), then exports `RootAccessibleInterface`
   (`bus.rs:96`) and `CacheInterface` at `cache_path()` (`bus.rs:108`).
10. `sync_adapters` (`context.rs:158`) then activates or deactivates every adapter.

**The platform event loop and the worker.** There is no platform event loop in the unix adapter,
because there is no platform window system involvement. The two channels are: application to
adapter through `Adapter`'s methods, and adapter to D-Bus through the `Message` channel. The
worker is thread B. The `select!` loop at `context.rs:197` is the dispatcher, and
`process_adapter_message` (`context.rs:213`) is the processor, with one arm per `Message`
variant: `AddAdapter` at `:219`, `RemoveAdapter` at `:236`, `RegisterInterfaces` at `:241`,
`UnregisterInterfaces` at `:246`, `Event::Object` at `:256`, `Event::Window` at `:264`,
`Event::Document` at `:278`, `Event::Cache` marked `unreachable!` at `:286`,
`EmitCacheAdd` at `:290`, and `EmitCacheRemove` at `:295`.

**Back pressure.** Both `try_send` (`adapters/unix/src/adapter.rs:33`, `:161`) and the tokio
`send` (`:35`, `:163`) discard their result with `let _ =`. The channel is unbounded
(`context.rs:51`). Messages are never dropped and never block.

### 7.3 Zig counterpart

The whole file collapses. `Executor` is `zio.Runtime` (`~/zio/src/zio.zig:14`),
constructed with `Runtime.init(allocator, options)` (`zio/src/runtime.zig:1620`) and torn down
with `Runtime.deinit()` (`zio/src/runtime.zig:1759`). `zio.Runtime` already holds its own
`allocator: Allocator` field, which satisfies the house rule that allocators are parameters
without any extra work.

| Upstream | Zig |
|---|---|
| `Executor::new` `executor.rs:63` | `zio.Runtime.init(gpa, .{})` |
| `Executor::run` `executor.rs:82` | implicit; `zio` tasks run on the runtime |
| `Executor::spawn` `executor.rs:46` | `zio.spawn` (`zio/src/runtime.zig:1492`) |
| `thread::spawn` at `context.rs:55` | `zio.spawnBlocking` (`zio/src/runtime.zig:1506`) |
| `Task<T>` `executor.rs:103` | `zio.JoinHandle(T)` (`zio/src/runtime.zig:169`), which already has `join` (`:193`), `cancel` (`:260`) and `detach` (`:289`) |
| the two tick loops `context.rs:178` and `bus.rs:56` | one `zio` task per `goose` connection, awaiting socket readiness instead of calling `tick()` |
| `block_on` `adapters/unix/src/util.rs:12` | none. There is no blocking call in the Zig design. |

Two items fight the house rules and must be redesigned rather than ported. First, the two
process-wide `OnceLock` statics at `adapters/unix/src/context.rs:33` and `:34` are global state;
they become explicit `*AppContext` and `*MessageQueue` parameters threaded through `Adapter`,
`Callback` and `Bus`. Second, `zio.getCurrentTask()` (`zio/src/runtime.zig:1369`) is itself a
global accessor, so it may not be used in the logic; pass the task context as a parameter.

---

## 8. Function-by-function port surface

This section gives the public and `pub(crate)` surface of each adapter with its host dependency
and its Zig name. "C" in the dependency column means a system library is reached through FFI.

### 8.1 `accesskit_unix`

| Upstream item | `path:line` | Host dependency | Zig name |
|---|---|---|---|
| `pub use adapter::Adapter` | `adapters/unix/src/lib.rs:27` | none | re-export |
| `Callback::new` | `adapters/unix/src/adapter.rs:26` | none | `Callback.init` |
| `Callback::send_message` | `adapter.rs:31` | none | `Callback.sendMessage` |
| `Callback::register_interfaces` | `adapter.rs:40` | D-Bus | `Callback.registerInterfaces` |
| `Callback::unregister_interfaces` | `adapter.rs:45` | D-Bus | `Callback.unregisterInterfaces` |
| `Callback::emit_event` | `adapter.rs:58` | D-Bus | `Callback.emitEvent` |
| `AdapterState` | `adapter.rs:80` | none | `AdapterState` union(enum) |
| `pub struct Adapter` | `adapter.rs:123` | none | `Adapter` |
| `Adapter::new` | `adapter.rs:133` | none | `Adapter.init` |
| `Adapter::send_message` | `adapter.rs:159` | none | `Adapter.sendMessage` |
| `Adapter::set_root_window_bounds` | `adapter.rs:173` | none | `Adapter.setRootWindowBounds` |
| `Adapter::update_if_active` | `adapter.rs:196` | none | `Adapter.updateIfActive` |
| `Adapter::update_window_focus_state` | `adapter.rs:222` | none | `Adapter.updateWindowFocusState` |
| `Drop for Adapter` | `adapter.rs:240` | none | `deinit` |
| `enum Message` | `adapter.rs:246` | none | `Message` union(enum) |
| `get_or_init_app_context` | `adapters/unix/src/context.rs:43` | none | delete; pass `*AppContext` |
| `get_or_init_messages` | `context.rs:47` | D-Bus | `startEventLoop` |
| `activate_adapter` | `context.rs:83` | none | `activateAdapter` |
| `deactivate_adapter` | `context.rs:113` | none | `deactivateAdapter` |
| `bus_after_status_change` | `context.rs:142` | D-Bus | `busAfterStatusChange` |
| `sync_adapters` | `context.rs:158` | none | `syncAdapters` |
| `run_event_loop` | `context.rs:169` | D-Bus | `runEventLoop` |
| `process_adapter_message` | `context.rs:213` | D-Bus | `processAdapterMessage` |
| `block_on` | `adapters/unix/src/util.rs:12` | none | delete |
| `map_error` | `util.rs:26` | none | `mapError` |
| `map_error_from_node` | `util.rs:40` | none | `mapErrorFromNode` |
| `Bus::new` | `adapters/unix/src/atspi/bus.rs:39` | D-Bus | `Bus.init` |
| `Bus::register_root_node` | `bus.rs:76` | D-Bus | `Bus.registerRootNode` |
| `Bus::register_interfaces` | `bus.rs:120` | D-Bus | `Bus.registerInterfaces` |
| `Bus::register_interface` | `bus.rs:183` | D-Bus | `Bus.registerInterface` |
| `Bus::unregister_interfaces` | `bus.rs:194` | D-Bus | `Bus.unregisterInterfaces` |
| `Bus::unregister_interface` | `bus.rs:245` | D-Bus | `Bus.unregisterInterface` |
| `Bus::emit_object_event` | `bus.rs:256` | D-Bus | `Bus.emitObjectEvent` |
| `Bus::emit_window_event` | `bus.rs:398` | D-Bus | `Bus.emitWindowEvent` |
| `Bus::emit_document_event` | `bus.rs:419` | D-Bus | `Bus.emitDocumentEvent` |
| `Bus::emit_cache_add` | `bus.rs:441` | D-Bus | `Bus.emitCacheAdd` |
| `Bus::emit_cache_remove` | `bus.rs:448` | D-Bus | `Bus.emitCacheRemove` |
| `Bus::emit_cache_signal` | `bus.rs:463` | D-Bus | `Bus.emitCacheSignal` |
| `Bus::emit_event` | `bus.rs:482` | D-Bus | `Bus.emitEvent` |
| `zbus_error_is_unrecoverable` | `bus.rs:505` | none | `isUnrecoverable` |
| `map_or_ignoring_recoverable_error` | `bus.rs:512` | none | `orDefault` |
| `ObjectId::Root`, `ObjectId::Node` | `adapters/unix/src/atspi/object_id.rs:23` | none | `ObjectId` union(enum) |
| `ObjectId::to_address` | `object_id.rs:29` | none | `ObjectId.toAddress` |
| `ObjectId::path` | `object_id.rs:33` | none | `ObjectId.path` |
| `cache_path` | `object_id.rs:18` | none | `cachePath` |
| `OwnedObjectAddress::new` | `adapters/unix/src/atspi/object_address.rs:23` | none | `ObjectAddress.init` |
| `OwnedObjectAddress::null` | `object_address.rs:30` | none | `ObjectAddress.null` |

### 8.2 `accesskit_atspi_common`

| Upstream item | `path:line` | Host dependency | Zig name |
|---|---|---|---|
| `AdapterCallback` trait | `adapters/atspi-common/src/callback.rs:11` | none | delete; a struct of function pointers |
| `AdapterChangeHandler` | `adapters/atspi-common/src/adapter.rs:30` | none | `ChangeHandler` |
| `add_node` | `adapter.rs:49` | none | `addNode` |
| `add_subtree` | `adapter.rs:84` | none | `addSubtree` |
| `remove_node` | `adapter.rs:91` | none | `removeNode` |
| `remove_subtree` | `adapter.rs:114` | none | `removeSubtree` |
| `emit_text_change_if_needed_parent` | `adapter.rs:121` | none | `emitTextChangeIfNeededParent` |
| `emit_text_change_if_needed` | `adapter.rs:184` | none | `emitTextChangeIfNeeded` |
| `emit_text_selection_change` | `adapter.rs:197` | none | `emitTextSelectionChange` |
| `enqueue_selection_changed_if_needed` | `adapter.rs:260` | none | `enqueueSelectionChangedIfNeeded` |
| `emit_selection_changed` | `adapter.rs:269` | none | `emitSelectionChanged` |
| `TreeChangeHandler::node_added` | `adapter.rs:281` | none | `nodeAdded` |
| `TreeChangeHandler::node_updated` | `adapter.rs:287` | none | `nodeUpdated` |
| `TreeChangeHandler::focus_moved` | `adapter.rs:324` | none | `focusMoved` |
| `TreeChangeHandler::node_removed` | `adapter.rs:345` | none | `nodeRemoved` |
| `next_adapter_id` | `adapter.rs:356` | none | make an `id` a parameter of `Adapter.init` |
| `pub struct Adapter` | `adapter.rs:360` | none | `Adapter` |
| `Adapter::new` | `adapter.rs:377` | none | `Adapter.init` |
| `Adapter::with_id` | `adapter.rs:397` | none | delete; `new` takes the id |
| `Adapter::with_wrapped_action_handler` | `adapter.rs:419` | none | merge into `init` |
| `Adapter::register_tree` | `adapter.rs:444` | none | `registerTree` |
| `Adapter::platform_node` | `adapter.rs:480` | none | `Adapter.platformNode` |
| `Adapter::root_id` | `adapter.rs:484` | none | `Adapter.rootId` |
| `Adapter::platform_root` | `adapter.rs:488` | none | `Adapter.platformRoot` |
| `Adapter::emit_object_event` | `adapter.rs:501` | none | `Adapter.emitObjectEvent` |
| `Adapter::emit_document_event` | `adapter.rs:513` | none | `Adapter.emitDocumentEvent` |
| `Adapter::set_root_window_bounds` | `adapter.rs:528` | none | `Adapter.setRootWindowBounds` |
| `Adapter::update` | `adapter.rs:533` | none | `Adapter.update` |
| `Adapter::update_window_focus_state` | `adapter.rs:541` | none | `Adapter.updateWindowFocusState` |
| `Adapter::window_created` | `adapter.rs:547` | none | `windowCreated` |
| `Adapter::window_activated` | `adapter.rs:551` | none | `windowActivated` |
| `Adapter::window_deactivated` | `adapter.rs:564` | none | `windowDeactivated` |
| `Adapter::window_destroyed` | `adapter.rs:576` | none | `windowDestroyed` |
| `Drop for Adapter` | `adapter.rs:609` | none | `deinit` |
| `Context::new` | `adapters/atspi-common/src/context.rs:54` | none | `Context.init` |
| `Context::read_tree` | `context.rs:68` | none | `Context.readTree` |
| `Context::do_action` | `context.rs:76` | none | `Context.doAction` |
| `AppContext::new` | `context.rs:99` | none | `AppContext.init` |
| `AppContext::push_adapter` | `context.rs:113` | none | `AppContext.pushAdapter` |
| `AppContext::remove_adapter` | `context.rs:117` | none | `AppContext.removeAdapter` |
| `NodeWrapper::interfaces` | `adapters/atspi-common/src/node.rs:484` | none | `NodeWrapper.interfaces` |
| `NodeWrapper::notify_changes` | `node.rs:593` | none | `NodeWrapper.notifyChanges` |
| `PlatformNode::new` | `node.rs:716` | none | `PlatformNode.init` |
| `PlatformNode::resolve` | `node.rs:796` | none | delete; inline the lock, upgrade and unlock |
| the 70 public `PlatformNode` accessors, `node.rs:840` to `node.rs:1772` | `node.rs` | none | mechanical camelCase |
| `PlatformRoot::new` | `node.rs:1810` | none | `PlatformRoot.init` |
| `PlatformRoot::map_descendant_cache_nodes` | `node.rs:1973` | none | `mapDescendantCacheNodes` |
| `enum NodeIdOrRoot` | `node.rs:2049` | none | `NodeIdOrRoot` union(enum) |
| `struct CacheNode` | `node.rs:2054` | none | `CacheNode` |
| `WindowBounds::new` | `adapters/atspi-common/src/util.rs:19` | none | `WindowBounds.init` |
| `enum Error` | `adapters/atspi-common/src/error.rs:9` | none | `Error` error set |
| `enum Event` | `adapters/atspi-common/src/events.rs:12` | none | `Event` union(enum) |
| `enum ObjectEvent` | `events.rs:46` | none | `ObjectEvent` union(enum) |
| `struct Action` | `adapters/atspi-common/src/action.rs:10` | none | `Action` |
| `struct Rect` | `adapters/atspi-common/src/rect.rs:12` | none | `Rect` |
| `struct AppContext` | `context.rs:90` | none | `AppContext` |
| `simplified-api` facade, 977 lines | `adapters/atspi-common/src/simplified.rs:22` | none | delete; it is a test client, not a port surface |

### 8.3 `accesskit_windows`

All C dependencies are `uiautomationcore.dll`, `user32`, `ole32`, `gdi32` and `oleaut32`. See
section 4.1 and 4.2 for the symbol list. The port surface is summarised here; `node.rs` alone has
more than 100 functions and the full list is in `docs/30-port-design.md` rather than here.

| Upstream item | `path:line` | Host dependency | Zig name |
|---|---|---|---|
| `Adapter::new` | `adapters/windows/src/adapter.rs:423` | UIA | `Adapter.init` |
| `Adapter::with_wrapped_action_handler` | `adapter.rs:436` | UIA | `Adapter.init` |
| `Adapter::update_if_active` | `adapter.rs:463` | none | `Adapter.updateIfActive` |
| `Adapter::update_window_focus_state` | `adapter.rs:500` | none | `Adapter.updateWindowFocusState` |
| `Adapter::handle_wm_getobject` | `adapter.rs:534` | UIA | `Adapter.handleWmGetobject` |
| `init_uia` | `adapter.rs:596` | UIA `UiaLookupId` | `initUia` |
| `From<WmGetObjectResult> for LRESULT` | `adapter.rs:622-624` | UIA `UiaReturnRawElementProvider` | `wmGetObjectResultToLresult` |
| `QueuedEvents::raise` | `adapter.rs:643` | UIA `UiaRaiseAutomationEvent` | `QueuedEvents.raise` |
| `Context` | `adapters/windows/src/context.rs:33` | none | `Context` |
| `Context::read_tree` | `context.rs:68` | none | `Context.readTree` |
| `NodeWrapper`, 58 accessors | `adapters/windows/src/node.rs:52-771` | none | `NodeWrapper` |
| `PlatformNode` COM object | `node.rs:805` | COM | `PlatformNode` with `IUnknown` + 13 vtables |
| `PlatformNode::new` | `node.rs:811` | COM | `PlatformNode.init` |
| `properties!` macro | `node.rs:1183` | none | delete; write the getter loop |
| `patterns!` macro | `node.rs:1245` | none | delete; write the vtables |
| `PlatformRange` COM object | `adapters/windows/src/text.rs:210` | COM | `PlatformRange` |
| `PlatformRange::new` | `text.rs:216` | none | `PlatformRange.init` |
| `wnd_proc` | `adapters/windows/src/subclass.rs:44` | Win32 | `AccessKitSubclassWindowProc` |
| `SubclassImpl::install` | `subclass.rs:95` | Win32 `SetWindowLongPtrW` | `SubclassImpl.install` |
| `SubclassImpl::uninstall` | `subclass.rs:126` | Win32 | `SubclassImpl.uninstall` |
| `SubclassingAdapter::new` | `subclass.rs:162` | Win32 | `SubclassingAdapter.init` |
| `StringBuffer` | `adapters/windows/src/util.rs:36` | none | `StringBuffer` |
| `Variant`, 18 conversions | `util.rs:116` to `util.rs:283` | `oleaut32` | `Variant` |
| `safe_array_from_i32_slice` | `util.rs:315` | `oleaut32` | `safeArrayFromI32Slice` |
| `enum QueuedEvent` | `util.rs:335` | UIA | `QueuedEvent` union(enum) |
| `client_top_left` | `util.rs:376` | GDI `ClientToScreen` | `clientTopLeft` |
| `window_title` | `util.rs:384` | Win32 | `windowTitle` |
| `struct WindowHandle` | `adapters/windows/src/window_handle.rs:10` | none | `extern struct { hwnd: HWND }` |

### 8.4 `accesskit_macos` and `accesskit_ios`

Both use the same three mechanisms: AppKit or UIKit accessibility symbols, the Objective-C
runtime, and one Objective-C method per a11y node. The full per-selector surface is in
`docs/30-port-design.md`; the structural items are listed here.

| Upstream item | `path:line` | Host dependency | Zig name |
|---|---|---|---|
| `Adapter::new` (macOS) | `adapters/macos/src/adapter.rs:89` | AppKit | `Adapter.init` |
| `Adapter::update_if_active` (macOS) | `adapter.rs:114` | none | `Adapter.updateIfActive` |
| `Adapter::update_view_focus_state` (macOS) | `adapter.rs:151` | none | `Adapter.updateViewFocusState` |
| `Adapter::view_children` (macOS) | `adapter.rs:223` | AppKit | `Adapter.viewChildren` |
| `Adapter::focus` (macOS) | `adapter.rs:248` | AppKit | `Adapter.focus` |
| `Adapter::hit_test` (macOS) | `adapter.rs:275` | AppKit | `Adapter.hitTest` |
| `Context::new` (macOS) | `adapters/macos/src/context.rs:55` | none | `Context.init` |
| `Context::get_or_create_platform_node` (macOS) | `context.rs:70` | none | `Context.getOrCreatePlatformNode` |
| `Drop for Context` (macOS) | `context.rs:91` | AppKit | `deinit` |
| `QueuedEvents::raise` (macOS) | `adapters/macos/src/event.rs:126` | AppKit | `QueuedEvents.raise` |
| `ns_role` table | `adapters/macos/src/node.rs:36` | none | comptime table |
| `ns_sub_role` table | `adapters/macos/src/node.rs:244` | none | comptime table |
| `PlatformNode` class | `adapters/macos/src/node.rs:396` | AppKit | `objc_allocateClassPair` |
| `add_focus_forwarder_to_window_class` | `adapters/macos/src/patch.rs:39` | AppKit + ObjC runtime | `addFocusForwarderToWindowClass` |
| `SubclassingAdapter::new` (macOS) | `adapters/macos/src/subclass.rs:144` | ObjC runtime | `SubclassingAdapter.init` |
| `Adapter::new` (iOS) | `adapters/ios/src/adapter.rs:344` | UIKit | `Adapter.init` |
| `any_assistive_tech_running` (iOS) | `adapter.rs:97` | UIKit | `anyAssistiveTechRunning` |
| `observed_notification_names` (iOS) | `adapter.rs:105` | UIKit | `observedNotificationNames` |
| `try_activate` (iOS) | `adapter.rs:190` | none | `tryActivate` |
| `try_deactivate` (iOS) | `adapter.rs:208` | none | `tryDeactivate` |
| `Adapter::view_did_appear` (iOS) | `adapter.rs:444` | none | `Adapter.viewDidAppear` |
| `filter_for_is_accessibility_element` (iOS) | `adapters/ios/src/filters.rs:27` | none | `filterForIsAccessibilityElement` |
| `dlsym` block (iOS) | `adapters/ios/src/util.rs:73` | `libSystem` | `std.DynLib`; delete the block |
| `toggle_button_trait` (iOS) | `util.rs:77` | `libSystem` | `toggleButtonTrait` |
| `SubclassingAdapter::for_window` (iOS) | `adapters/ios/src/subclass.rs:270` | UIKit | `SubclassingAdapter.forWindow` |

### 8.5 `accesskit_android`

| Upstream item | `path:line` | Host dependency | Zig name |
|---|---|---|---|
| `Adapter` | `adapters/android/src/adapter.rs:267` | JNI | `Adapter` |
| `AdapterChangeHandler` | `adapter.rs:51` | none | `ChangeHandler` |
| `get_or_init_tree` | `adapter.rs:212` | none | `getOrInitTree` |
| `Adapter::update_if_active` | `adapter.rs:287` | none | `Adapter.updateIfActive` |
| `Adapter::create_accessibility_node_info` | `adapter.rs:322` | JNI | `Adapter.createAccessibilityNodeInfo` |
| `Adapter::find_focus` | `adapter.rs:395` | JNI | `Adapter.findFocus` |
| `Adapter::perform_action` | `adapter.rs:804` | JNI | `Adapter.performAction` |
| `Adapter::on_hover_event` | `adapter.rs:867` | JNI | `Adapter.onHoverEvent` |
| `traverse_text` | `adapter.rs:647` | none | `traverseText` |
| `NodeWrapper::populate_node_info` | `adapters/android/src/node.rs:196` | JNI | `NodeWrapper.populateNodeInfo` |
| `NodeWrapper::class_name` | `node.rs:124` | none | comptime table |
| `QueuedEvents::raise` | `adapters/android/src/event.rs:347` | JNI | `QueuedEvents.raise` |
| `send_completed_event` | `event.rs:52` | JNI | `sendCompletedEvent` |
| `enum QueuedEvent` | `event.rs:294` | none | `QueuedEvent` union(enum) |
| `PlatformAction::from_java` | `adapters/android/src/action.rs:36` | JNI | `PlatformAction.fromJava` |
| `struct NodeIdMap` | `adapters/android/src/util.rs:134` | none | `NodeIdMap` |
| `is_accessibility_enabled` | `util.rs:245` | JNI | `isAccessibilityEnabled` |
| `run_callback` | `adapters/android/src/inject.rs:137` | JNI | `runCallback` |
| `create_accessibility_node_info` | `inject.rs:149` | JNI | `createAccessibilityNodeInfo` |
| `find_focus` | `inject.rs:163` | JNI | `findFocus` |
| `perform_action` | `inject.rs:177` | JNI | `performAction` |
| `on_hover_event` | `inject.rs:201` | JNI | `onHoverEvent` |
| `delegate_class` | `inject.rs:222` | JNI | `delegateClass` |
| `post_to_ui_thread` | `inject.rs:107` | JNI | `postToUiThread` |
| `InjectingAdapter::new` | `inject.rs:329` | JNI | `InjectingAdapter.init` |
| `InjectingAdapter::update_if_active` | `inject.rs:402` | JNI | `InjectingAdapter.updateIfActive` |

---

## 9. The Zig-first ladder for each host dependency

Decision order: rung 1 Zig standard library, rung 2 a Zig package pinned in `build.zig.zon`,
rung 3 a Zig `translate-c` binding to a system C library, rung 4 a hand-written C shim. The
"why not higher" column names what blocks the higher rungs.

| Host dependency | Rung | Bindable by `translate-c` as is? | Why not higher, and why not lower |
|---|---|---|---|
| Unix domain sockets, `SCM_CREDENTIALS` for D-Bus SASL | 1 | n/a | `std.net` and `std.posix` cover this. Rung 1 is the top. |
| `environ` lookup for `AT_SPI_BUS_ADDRESS` and `DBUS_SESSION_BUS_ADDRESS` | 1 | n/a | `std.process.Environ` or an explicit environment map. Already how a Zig program should read it. |
| **`dlsym` for iOS weak constants** | 1 | n/a | `std.DynLib.open` and `.lookup` replace the hand-written block at `adapters/ios/src/util.rs:73-75` and the `-2` sentinel at `:71`. |
| **D-Bus** | **2** | n/a | See section 9.1. |
| Objective-C runtime (`objc_msgSend`, `class_addMethod`, `object_setClass`, `objc_setAssociatedObject`) | 3 | Yes | Apple ships no header for the runtime in a form `translate-c` accepts `[INFERENCE]`. The candidate Zig packages were searched; none found. `translate-c` against `<objc/runtime.h>` binds the plain C functions, but the `msgSend` variadic form has a non-representable type, so every message send needs a typed wrapper written by hand. That is a Zig file, not a C shim. |
| `objc_msgSend` | 3, with hand-written Zig wrappers | No | Variadic. `translate-c` cannot bind a variadic with mixed argument types. Zig needs one `extern fn` plus one wrapper per selector, which is what `adapters/macos/src/node.rs` does through `msg_send!`. |
| CoreGraphics `CGColor` | 1 | n/a | The source does not call CoreGraphics. It declares an opaque shim, `#[repr(C)] struct CGColor { _private: [u8; 0] }`, at `adapters/macos/src/util.rs:88-91` and obtains a value through the ObjC message `msg_send![&ns_color, CGColor]` at `util.rs:106`. A Zig port uses `opaque {}` for `CGColor` and `@cImport` only for `<CoreGraphics/CGColor.h>` if it needs more. |
| Win32, UIA, COM | 3 | Yes | Microsoft ships `<windows.h>`, `<ole2.h>`, `<olectl.h>` and the UIA headers. `translate-c` binds them. Two caveats. First, COM vtables are not structures with named fields, so every `IUIAutomation*` method becomes a manual vtable struct; that is Zig code. Second, `UiaLookupId` and the other `Uia*` entry points live in `uiautomationcore.dll` and are declared in `<uiautomationclient.h>`, which does bind. |
| `BSTR`, `VARIANT`, `SAFEARRAY` | 3 | Partly | `translate-c` binds the declarations, but the `VARIANT` union is a tagged union whose arm is selected by a parallel `VARTYPE` field, a pattern `translate-c` does not model. `adapters/windows/src/util.rs:116-283` hand-writes 18 `From` impls to work around it. The Zig port needs `extern union` plus its own discriminant handling. That is Zig. |
| JNI | 2 or 3 | n/a | JNI is a C ABI with no header on this machine because the NDK is not a dependency of this repository. The smallest honest option is a hand-written binding to the six `JNIEnv` function-table slots the adapter uses, which is a Zig file. Searched: no pure-Zig JNI package was found `[INFERENCE]`. |
| Android `AccessibilityNodeInfo` and friends | 3, by descriptor string | No | These are Java classes reached by JNI method name and descriptor, not by C symbols. `translate-c` has nothing to bind. The names and descriptors come from `adapters/android/src/inject.rs:257-291` and are checked-in string constants. |
| The `classes.dex` blob | n/a | n/a | Not a library dependency. See section 5.3. |

### 9.1 D-Bus, in detail

This is the dependency most likely to force a C shim, so the search was done properly.

A pure-Zig D-Bus implementation exists. It is `goose`, from `https://github.com/luxluth/goose`,
published on zigpkg.dev as `luxluth/goose`, MIT licensed, with an empty dependency list in its
manifest, so it is pure Zig with no C.

Version compatibility, which is the decisive fact:

```
$ curl -sL https://raw.githubusercontent.com/luxluth/goose/master/build.zig.zon
.minimum_zig_version = "0.17.0",   .version = "4.0.0"

$ curl -sL https://raw.githubusercontent.com/luxluth/goose/v3.3.0/build.zig.zon
.minimum_zig_version = "0.16.0",   .version = "3.3.0"

$ curl -sL https://raw.githubusercontent.com/luxluth/goose/v3.2.1/build.zig.zon
.minimum_zig_version = "0.16.0",   .version = "3.2.1"
```

The project pins Zig 0.16.0. So the candidate is
`git+https://github.com/luxluth/goose#v3.3.0`, not the latest tag. Tags present, from
`git ls-remote --tags`: `v0.2.2`, `v1.0.0`, `v1.0.1`, `v2.0.0`, `v2.1.0`, `v2.2.0`, `v2.2.1`,
`v2.2.2`, `v2.2.3`, `v3.0.0`, `v3.1.0`, `v3.2.0`, `v3.2.1`, `v3.3.0`, `v4.0.0`.

Completeness against what AccessKit needs, read from the project README at `v3.3.0`:

| Operation AccessKit needs | Where it is needed | goose |
|---|---|---|
| Connect to the session bus | `adapters/unix/src/context.rs:58` | yes, `goose.Connection.init(allocator, .Session, io, init.environ_map)` |
| Connect to a second bus at a runtime address | `adapters/unix/src/atspi/bus.rs:48` | yes, `goose.Connection.initWithBackend`, and the bus list includes Accessibility |
| SASL `EXTERNAL` | implicit | yes, stated in the README |
| Export objects at fixed paths with typed methods | `bus.rs:83`, `:96`, `:108` | yes, `conn.registerObject` plus automatic introspection |
| Serve `org.freedesktop.DBus.Properties` reads | `accessible.rs:35` and the other `#[zbus(property)]` markers | yes, `goose.Property(T, .ReadWrite)` |
| Emit a signal with a structured body | `bus.rs:490` | yes, `Proxy.connectSignal`; marshalling is compile-time reflection over Zig types |
| Subscribe to a property change | `adapters/unix/src/context.rs:185` | yes, it handles signals and signals are part of the type system |
| Zero background threads | needed to keep one event-loop thread | yes, the `.poll` backend with `conn.getFd()` |

Two gaps to verify before committing to the pin, both `[INFERENCE]` because I read the README and
not the source tree. First, the exact v3.3.0 API shape may differ from the v4.0.0 README text I
quoted. Second, the AT-SPI event body is a heterogeneous dictionary with `detail1`, `detail2`,
`kind` and `any_data` keys, built as `EventBodyBorrowed` at
`adapters/unix/src/atspi/bus.rs:288` and consumed at `bus.rs:314-327`. I did not verify that
goose can marshal that exact shape. If it cannot, the smallest honest fix is a hand-written
marshal function for the body only, in Zig, and nothing else changes.

Three other pure-Zig candidates were found and rejected on evidence, not preference:
`0xCatPKG/dbuz` on GitHub, `erffy/plume` and `QuaternionWake/qbus` on Codeberg. None has a
zigpkg.dev entry, so `build.zig.zon` cannot fetch them by version. None was checked for Zig
version compatibility. `goose` is the only candidate that `zig fetch` can pin.

The fallback if goose fails verification is rung 3 against `libdbus-1`, which is present on this
machine at pkg-config version 1.14.10. `libdbus` does not bind cleanly: `dbus_connection_send_with_reply_and_block` takes a varargs message, and `dbus_message_iter_*` is a hand-rolled tagged-union protocol. That combination is exactly the rung 4 trigger described in the constraint update, so it should be the last resort, not the plan.

## 10. Portability classification per adapter

The task brief asked for each C dependency to be marked as bindable by `translate-c` as is,
needing a C shim, or not portable. Restated per adapter:

| Adapter | Classification | Reason |
|---|---|---|
| `accesskit_unix` | **Not applicable.** It links no C library. | All protocol work is in `goose`, rung 2. |
| `accesskit_atspi_common` | **Not applicable.** No C library. | It is pure data translation. |
| `accesskit_windows` | **Bindable by `translate-c` as is**, with hand-written Zig for COM vtables and `VARIANT`. | Win32, UIA and COM all ship C headers. No rung 4 shim is needed. |
| `accesskit_macos` | **Bindable by `translate-c` as is** for `class_addMethod`, `object_setClass` and the two `NSAccessibilityPostNotification*` functions. **Hand-written Zig needed** for every `msgSend`, because `objc_msgSend` is variadic. | No C shim. |
| `accesskit_ios` | Same as macOS, plus `dlsym` which is **rung 1** via `std.DynLib`. | The hand-written `extern "C"` block at `adapters/ios/src/util.rs:73-75` is deleted outright. |
| `accesskit_android` | **Not portable to this build.** JNI needs an NDK that this repository does not declare. The adapter must be compiled into an Android `.so` with a separate build configuration. | The Zig code is portable; the build is not. Record this in `docs/40-plan.md` as a separate milestone. |
| `accesskit_winit` | **Recommendation: not ported.** See section 6.2. | |

**No adapter requires a rung 4 hand-written C shim.** This is the finding that most affects the
plan. Every platform dependency either has a Zig implementation at rung 1 or 2, or binds cleanly
at rung 3.

## 11. Constructs that exist only because of Rust

Every row names the Zig replacement. This table is the input to `docs/30-port-design.md`.

| Rust construct | Where | Why Rust needs it | Zig replacement |
|---|---|---|---|
| `pub trait AdapterCallback` | `adapters/atspi-common/src/callback.rs:11` | trait object for a pluggable sink | a struct of three function pointers plus a `*anyopaque` context |
| `Box<dyn ActivationHandler + Send>` | `adapters/unix/src/adapter.rs:249` | type erasure across the message queue | `{ vtable: *const VTable, ctx: *anyopaque }` |
| `Arc<dyn ActionHandlerNoMut + Send + Sync>` | `adapters/unix/src/adapter.rs:84` | shared mutable handler without `&mut` | handler struct plus a `std.Thread.Mutex` |
| `ActionHandlerWrapper<H>(Mutex<H>)` | `adapters/atspi-common/src/context.rs:21` | bridges `&mut self` handler to `&self` | explicit mutex field |
| `impl Trait` in argument position, 50 uses in `PlatformNode` | `adapters/atspi-common/src/node.rs:919`, `:972` and the rest | generic methods without naming the type | comptime generic functions |
| `resolve<F, T>` combinators, 8 of them | `adapters/atspi-common/src/node.rs:755`, `:768`, `:782`, `:796`, `:803`, `:817`; `adapters/windows/src/node.rs:869`, `:879`, `:889`, `:896` | higher-ranked `FnOnce` closures that re-borrow the tree | inline lock, upgrade, body, unlock at each call site |
| `RwLockReadGuard` held across a callback | `adapters/atspi-common/src/adapter.rs:535` then `:538` | the guard is a value with a destructor | explicit scope plus `defer` |
| `drop(tree)` before calling user code | `adapters/windows/src/text.rs:291`, `adapters/windows/src/node.rs:928` | releases the guard before re-entering user code that could take the write lock | **This is a runtime requirement, not a borrow trick. Carry it over.** |
| `RefCell` and its borrow counting | `adapters/unix/src/adapter.rs:126`, `adapters/macos/src/context.rs:37`, `adapters/windows/src/subclass.rs:39` | interior mutability with a runtime check | plain mutable fields; the re-entrancy hazard becomes a scoping rule plus `defer` |
| `Weak<Context>` in both Windows COM objects | `adapters/windows/src/node.rs:806`, `adapters/windows/src/text.rs:211` | breaks the COM object to context to map of COM objects refcount cycle | **Keep it.** It is a cycle breaker, not a borrow trick. |
| `WeakTextRange` in `RwLock` | `adapters/windows/src/text.rs:212` | the borrow cannot escape, but the range indexes a tree that is replaced on every update | **Keep the weak form.** It is required for correctness, not for the borrow checker. |
| `TextRange<'a>` lifetimes tied to `&'a TreeState` | `adapters/windows/src/text.rs:24`, `:32`, `:51`, `:62` | proves a range cannot outlive the guard | `*const TreeState` plus the tree-version check `upgrade_range` already performs at `text.rs:25` |
| `declare_class!`, `#[method]`, `#[method_id]`, `#[inherits]` | `adapters/macos/src/node.rs:396`, `adapters/macos/src/subclass.rs:45`, `adapters/macos/src/patch.rs:53`, `adapters/ios/src/node.rs:200`, `adapters/ios/src/subclass.rs:40`, `adapters/ios/src/adapter.rs:245` | generates the Objective-C class at runtime | hand-written `objc_allocateClassPair`, `class_addMethod`, `objc_registerClassPair`. The `class_addMethod` wrapper is already vendored at `adapters/macos/src/patch.rs:53-79`; reuse that strategy and delete the macros. |
| `#[implement(...)]` for COM | `adapters/windows/src/node.rs:790`, `adapters/windows/src/text.rs:209` | generates the vtable and the `IUnknown` boilerplate | hand-written `VTable` structs and a `QueryInterface` switch |
| `properties!` and `patterns!` macros | `adapters/windows/src/node.rs:1183`, `:1245` | generate 21 property getters and 10 provider vtables from a table | comptime `inline for` over a table, generating the same vtables |
| `Serialize`, `Deserialize`, `Type`, `OwnedValue`, `Value` derives | `adapters/atspi-common/src/action.rs:9`, `rect.rs:9`, `adapters/unix/src/atspi/object_address.rs:16` | generates D-Bus marshalling | hand-written `marshal` and `unmarshal` per type, unit-tested against golden byte vectors |
| `phf_map!` static map | `adapters/atspi-common/src/text_attributes.rs:68` | compile-time perfect hash | a `switch` on the attribute name string |
| `impl From<X> for Y`, 18 times | `adapters/windows/src/util.rs:134-283` | ergonomic conversion | explicit named functions |
| `async`/`await` on `zbus` calls | `adapters/unix/src/atspi/bus.rs:39` and the rest | the D-Bus client is async | `async fn`, same shape; `zio` is already async |
| `tokio` and `async-io` feature duality | `adapters/unix/Cargo.toml:16-17`, 30 `#[cfg]` sites in `executor.rs` | support two runtimes | one runtime, `zio`. **Delete the duality.** |
| `impl Drop for X`, 12 sites | `adapters/unix/src/adapter.rs:240`, `adapters/atspi-common/src/adapter.rs:609`, `adapters/macos/src/context.rs:91`, `adapters/windows/src/subclass.rs:200`, `adapters/android/src/inject.rs:464` | RAII | `fn deinit` called explicitly, or an `errdefer` where the scope is a function |
| `static OnceLock` globals | `adapters/unix/src/context.rs:33`, `:34`; `adapters/android/src/inject.rs:223`, `:88`, `:101` | lazy process-wide singleton | delete; pass a pointer |
| `static AtomicUsize NEXT_ADAPTER_ID` | `adapters/atspi-common/src/adapter.rs:352` | process-wide id counter | make the id a parameter of `Adapter.init` |
| `thread_local!` scratch pool | `adapters/windows/src/util.rs:28-30` | per-thread `Vec<Vec<u16>>` so concurrent UIA callbacks never share a buffer | `threadlocal var`, or thread the `[]u16` through `NodeWrapper`, which already carries one at `adapters/windows/src/node.rs:54` |
| `static_assertions` | `adapters/windows/src/node.rs:41`, `:1536`; `adapters/windows/src/text.rs:649`; `adapters/windows/src/window_handle.rs:29` | compile-time `Send + Sync` and size checks | `comptime { std.debug.assert(...) }`, or nothing, since Zig has no `Send` bound |
| `hashbrown` with `default-hasher` | workspace `Cargo.toml:30`, used at `adapters/macos/src/context.rs:38` | a fast hash map | `std.AutoHashMap`. The hasher does not need to match; these maps are never persisted or iterated in hash order. |
| `simplified-api` feature, 977 lines | `adapters/atspi-common/src/simplified.rs:22` | an in-process AT-SPI client for tests | **Delete.** It is a test client, not part of any adapter. |
| `#[cfg(test)] mod tests`, 1500 lines across the set | `adapters/ios/src/node.rs:518-1076`, `adapters/ios/src/filters.rs:54-129`, `adapters/windows/src/tests/` | test modules | `test` blocks; the iOS `node.rs` test module alone is 560 lines |

## 12. Compliance with the house rules

The rules are from `~/ozai/AGENTS.md` section 2.

**`io` threaded explicitly, never global.** The adapters fight this. `AppContext` and the
message channel are process-wide `OnceLock` statics at
`adapters/unix/src/context.rs:33` and `:34`. zbus owns its sockets internally. The Zig port must
put `io: std.Io` and the allocator in the `Adapter` struct and pass them down through `Bus`,
`Callback` and every interface object. The goose `.poll` backend (`conn.getFd()`) makes this
possible because it hands the file descriptor back for registration on an external loop.

**State is a parameter, not a capture.** Two places fight this. `Callback`
(`adapters/unix/src/adapter.rs:21`) captures a `Sender<Message>` at construction and every
callback method reads it. `Adapter` (`adapters/unix/src/adapter.rs:123`) captures `messages`,
`id` and `state`. In Zig, `registerInterfaces(self: *Callback, ...)` keeps the sender in the
struct, which is an explicit parameter at the call site, not a capture. That is compliant.

**Network and event logic is pure over decoded input.** This is the rule the AT-SPI adapter
comes closest to satisfying already. `process_adapter_message`
(`adapters/unix/src/context.rs:213`) is a pure function of `atspi_bus`, `adapters` and
`message`. The tree diff in `AdapterChangeHandler` (`atapters/atspi-common/src/adapter.rs:38`) is
pure over the old and new node. `ObjectId::path` (`adapters/unix/src/atspi/object_id.rs:33`) is a
pure function. These port directly with no change. The parts that are not pure are the two tick
loops at `adapters/unix/src/context.rs:178` and `adapters/unix/src/atspi/bus.rs:56`, which are
replaced by socket-readiness awaits.

**Allocators are parameters.** Fights everywhere. Allocations happen inside `zbus`, inside the
`HashMap` growth at `adapters/atspi-common/src/context.rs:38`, and inside the string scratch pool
at `adapters/windows/src/util.rs:28-30`. The Zig port passes an allocator to every function that
can grow a buffer, and holds one in `Context`.

**Error sets are explicit.** Fights badly today. `accesskit_atspi_common::Error`
(`adapters/atspi-common/src/error.rs:9`) is a six-variant enum, which maps directly to a Zig
error set, so that one is easy. The hard case is `map_or_ignoring_recoverable_error`
(`adapters/unix/src/atspi/bus.rs:512`), which swallows every error except two and returns a
default. The Zig port keeps the same behaviour but makes the surviving cases explicit:
`error{ BusUnavailable, InterfaceExists, MissingParameter }` plus a default arm, so that a
comptime sweep over `@typeInfo(ErrorSet)` can prove every path is handled.

**Loops have fixed upper bounds.** `add_subtree` (`adapters/atspi-common/src/adapter.rs:84`),
`remove_subtree` (`:114`), `map_descendants` (`adapters/atspi-common/src/node.rs:1930`) and
`map_descendant_cache_nodes` (`:1973`) are unbounded recursion. A Zig port must either accept a
maximum depth and return `error.TreeTooDeep`, or use an explicit worklist with a fixed-capacity
buffer. Say which in `docs/30-port-design.md`.

**No backwards compatibility.** There is nothing to keep. The `tokio` feature
(`adapters/unix/Cargo.toml:17`) is deleted, the `async-io` feature (`:16`) is deleted, the
`simplified-api` feature (`adapters/atspi-common/Cargo.toml:15`) is deleted, and
`accesskit_winit` is not ported. One decision is genuinely open and belongs to the design wave:
the Android `embedded-dex` feature
(`adapters/android/Cargo.toml:16`) exists to work around the absence of a Java class on the
classpath. Section 5.3 recommends keeping that behaviour rather than dropping it, but as a
checked-in `.dex` plus a reproducible `d8` step, not as a Cargo feature.

## 13. Adapter priority

**Recommendation: port `accesskit_atspi_common` and `accesskit_unix` first, in that order.
Together they are 7177 lines of Rust and they are the only adapters that can be tested on this
machine.**

The reason is testability, not popularity. Three pieces of evidence from this host.

First, a D-Bus session bus is live and owns `org.a11y.Bus`:

```
$ dbus-send --session --print-reply --dest=org.freedesktop.DBus \
    /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner string:org.a11y.Bus
   boolean true

$ dbus-send --session --print-reply --dest=org.freedesktop.DBus \
    /org/freedesktop/DBus org.freedesktop.DBus.GetConnectionUnixProcessID string:org.a11y.Bus
   uint32 55300

$ ps -o pid,cmd -p 55300
    PID COMMAND
  55300 /usr/libexec/at-spi2/at-spi-bus-launcher
```

Second, the accessibility bus itself answers:

```
$ dbus-send --session --print-reply --dest=org.a11y.Bus /org/a11y/bus org.a11y.Bus.GetAddress
   string "unix:path=/run/user/33156/at-spi/bus"

$ dbus-send --bus=unix:path=/run/user/33156/at-spi/bus --print-reply \
    --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames
   array [ string "org.freedesktop.DBus"  string ":1.0" ]
```

Third, `DISPLAY` and `WAYLAND_DISPLAY` are both empty, so no X11 or Wayland adapter could run
here, and there is no macOS, iOS, Windows or Android target on this machine at all. The unix
adapter needs none of those.

Two caveats on that evidence, both of which affect the plan.

`org.a11y.Status` `IsEnabled` returns `false` on this host, and `org.a11y.atspi.Registry` is not
activatable (`ServiceUnknown: The name is not activatable`):

```
$ dbus-send --session --print-reply --dest=org.a11y.Bus /org/a11y/bus \
    org.freedesktop.DBus.Properties.Get string:org.a11y.Status string:IsEnabled
   variant       boolean false
```

`at-spi2-registryd` and `at-spi2d` are not installed; only `at-spi-bus-launcher` is. So the
`IsEnabled == true` branch of `bus_after_status_change`
(`adapters/unix/src/context.rs:142`) cannot be reached against the system bus as configured. Two
responses, and the plan needs both. First, `at-spi2-registryd` is a package install away on a
test machine, so the full path is testable on a prepared host. Second, and more important for
this project's test strategy, the bus can be driven without the registry at all: `dbus-daemon`
and `dbus-run-session` are both present, so the test suite can start a private session bus with
`AT_SPI_BUS_ADDRESS` pointed at it, which is the same injection point the production code reads
at `adapters/unix/src/atspi/bus.rs:43`. That gives a hermetic, fail-N-injectable bus with no
system dependency, which is exactly what the house rules ask for.

**The trade-off, stated explicitly.** Porting AT-SPI first buys a testable target and a
dependency ladder with no rung 4 entry, because `goose` covers the whole protocol at rung 2. It
costs the largest single abstraction in the set. The two crates together are 6368 lines of
protocol work: `atspi-common` 4417 plus `adapters/unix/src/atspi` 1951. Of that,
`node.rs` at 2065 lines and `simplified.rs` at 977 lines are mostly wide, repetitive mapping
tables from AccessKit types onto AT-SPI types. Those tables port well and test well, but they
buy no platform coverage. A reviewer who wants a thin vertical slice first will point at
`adapters/windows`, where `node.rs` is 1539 lines and `text.rs` is 652, and where the subclass
install is 15 lines (`adapters/windows/src/subclass.rs:110-115`). That route cannot be run,
built, or exercised on this host at all, so every claim about it would be unverified.

Recommend AT-SPI first, accept the size, and say so plainly in `docs/40-plan.md` rather than
discovering the cost halfway through.

### 13.1 What can be tested where

| Adapter | Builds on this host | Runs on this host | Level of confidence available today |
|---|---|---|---|
| `accesskit_atspi_common` | yes, pure logic | yes, in-process | full unit tests, no platform needed |
| `accesskit_unix` | yes, needs `goose` and `zio` | yes, against a private `dbus-daemon` | full integration test |
| `accesskit_winit` | yes, but not ported | n/a | n/a |
| `accesskit_windows` | no, needs an MSVC or MinGW target | no | cross-compile only, no execution |
| `accesskit_macos` | no, needs the macOS SDK | no | cross-compile only |
| `accesskit_ios` | no, needs the iOS SDK | no | cross-compile only |
| `accesskit_android` | no, needs the NDK and an APK | no | build only |
