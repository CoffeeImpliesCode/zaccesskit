# Display server surface: what the port does and does not need

Consumed by `docs/30-port-design.md`.

This document was first assigned the title "X11 and Wayland surface". The title
changed after the integration owner checked the reference tree. `accesskit_unix`
0.24.0 at commit `466e24e252103f4d82bd6fbab98141b551e46e0c` contains no X11, no XCB
and no Wayland code. It contains one doc comment that mentions both words. There
is no "two path" surface to document. The document now proves the absence, records
what the application must supply in its place, and answers the event loop question
that the real transport, the D-Bus socket, needs.

Sections about AT-SPI protocol detail live in `docs/13-atspi-protocol.md`. This
document does not repeat them.

Evidence convention: `path:line` for code, the exact command plus its output for
everything else. Anything not directly observed is marked `[INFERENCE]`.

---

## 1. The absence, proved

### 1.1 The greps

Command and verbatim output, run from the AccessKit checkout root:

```
$ grep -rniE 'xcb|wayland|x11|xlib|xkb|wl_|display_server|wl_display' adapters/unix/src adapters/unix/Cargo.toml
adapters/unix/src/adapter.rs:172:    /// Wayland, calling this method only makes sense under X11.
```

One hit. It is a comment.

```
$ grep -rnE 'extern "C"|#\[link|dlopen|libloading|build=' adapters/unix/src
```

No output, exit status 1.

```
$ ls adapters/unix/build.rs
ls: cannot access 'adapters/unix/build.rs': No such file or directory
```

### 1.2 The dependency list

`adapters/unix/Cargo.toml:19-38` is the complete dependency list. It is `accesskit`,
`accesskit_atspi_common`, `atspi`, `futures-lite`, `serde`, `zbus`, plus the
optional executor crates `async-channel`, `async-executor`, `async-task`,
`futures-util` and `tokio` with `tokio-stream`. No X11 crate, no XCB crate, no
Wayland crate, no `dlopen` crate.

`adapters/unix/Cargo.toml` has no `[build-dependencies]` and the crate has no
`build.rs`, so there is no code generation step that could have emitted bindings.

### 1.3 The only way into libxcb in the whole workspace

`git grep -l -i 'xcb' -- .` over the whole AccessKit checkout returns `Cargo.lock`
and nothing else. In that file the crate is `as-raw-xcb-connection`, and its only
consumer is `softbuffer`, listed at `Cargo.lock:1967` as a dependency of the
`softbuffer` package that begins at `Cargo.lock:1962`. `softbuffer` is a winit
dependency.

The X11 and Wayland features in this workspace come from winit, and
`adapters/winit/Cargo.toml` names them twice. The default feature set at `:16` carries
`winit/x11` and `winit/wayland`. The winit **dev**-dependency at `:46-49` asks for them
again:

```toml
[dev-dependencies.winit]
version = "0.30.5"
default-features = false
features = ["x11", "wayland", "wayland-dlopen", "wayland-csd-adwaita"]
```

Line 16 makes both backends the default for any build of `accesskit_winit`. Lines 46 to 49
make the example programs open under both display servers. Neither reaches the
accessibility adapter, and `adapters/unix/` names neither crate. The adapter never sees an
`xcb_connection_t`, a `Display *`, or a `struct wl_display *`.

### 1.4 The adapter's own description of itself

`adapters/unix/README.md` line 3: "It exposes an AccessKit accessibility tree
through the AT-SPI protocol." That is the whole contract.

### 1.5 What the adapter does not need

| It does not need | Because |
|---|---|
| A display server connection | The transport is a D-Bus socket named by `AT_SPI_BUS_ADDRESS` or by the `org.a11y.Bus` object on the session bus (`adapters/unix/src/atspi/bus.rs:43-46`). |
| Any X extension | No X symbol is called. See section 1.1. |
| Any Wayland protocol | No `wl_` symbol is called. See section 1.1. |
| A build script or code generator | No `build.rs`. See section 1.2. |
| A window manager | It never learns about a window. See section 2. |
| A keyboard or pointer device | No input device is opened. The adapter is a producer, not a consumer of key events. |

The last row matters for scope. The AT-SPI adapter publishes an accessibility tree.
It does not read keys and it does not synthesize input. `docs/13-atspi-protocol.md`
covers the tree and the event stream.

---

## 2. Where the application supplies the window facts

Because the adapter cannot observe a window, the application must push two facts
into it. These two calls are the entire display server contract.

### 2.1 `Adapter::set_root_window_bounds`

Declaration, `adapters/unix/src/adapter.rs:173`:

```rust
pub fn set_root_window_bounds(&mut self, outer: Rect, inner: Rect) {
```

The comment above it, added by commit `b0cf01a` on 2025-05-06 and preserved at
`adapters/unix/src/adapter.rs:166-172`, reads:

```
/// Set the bounds of the top-level window. The outer bounds contain any
/// window decoration and borders.
///
/// # Caveats
///
/// Since an application can not get the position of its window under
/// Wayland, calling this method only makes sense under X11.
```

What it does, `adapters/unix/src/adapter.rs:174-188`: it wraps the two rectangles
in a `WindowBounds`, takes the mutex on the shared state, and either stores the
value for later or forwards it to the live adapter with
`r#impl.set_root_window_bounds(new_bounds)`.

What the application must pass:

| Argument | Meaning | Source of truth in a ported application |
|---|---|---|
| `outer: Rect` | The window rectangle including decoration and borders. | The toolkit's outer position and outer size. |
| `inner: Rect` | The client area rectangle. | The toolkit's inner position and inner size. |

`Rect` is `accesskit/src/geometry.rs:337-345`. It holds `x0`, `y0`, `x1`, `y1`, each
an `f64`. Both rectangles are in screen coordinates. The toolkit usually supplies
position and size separately, so the caller converts them. The reference caller
does this at `adapters/winit/src/platform_impl/unix.rs:44-69` with
`Rect::from_origin_size(outer_position, outer_size)` and the matching inner pair.

The inner rectangle matters more than it looks. `adapters/atspi-common/src/util.rs:43-56`
computes the origin for every coordinate conversion the adapter performs:

```rust
fn origin(&self, parent: Option<NodeRef>, coord_type: CoordType) -> Point {
    match coord_type {
        CoordType::Screen => self.inner.origin(),
        CoordType::Window => Point::ZERO,
        CoordType::Parent => { ... }
    }
}
```

`CoordType::Screen` is answered from `inner.origin()` and nothing else. The
accessibility tree stores node coordinates relative to the window. The adapter
adds `inner.origin()` to reach screen coordinates, at
`adapters/atspi-common/src/util.rs:29-30`. Nine call sites in
`adapters/atspi-common/src/node.rs` depend on it, at lines 1135, 1152, 1165, 1206,
1517 and 1532 among others.

**The cost this puts on the port, named.** If an application never calls
`set_root_window_bounds`, then `root_window_bounds` keeps its `Default` value.
`WindowBounds` derives `Default` at `adapters/atspi-common/src/util.rs:12`, so the
inner origin is `(0, 0)`. Every AT-SPI screen coordinate the port emits is then
wrong by the window's position on screen. Screen readers still receive the events.
They place the focus rectangle in the wrong place. The failure is silent. A ported
application must therefore supply window geometry, or `docs/30-port-design.md`
must make the bounds a required parameter rather than an optional call.

Every caller in the reference tree:

| Caller | Location |
|---|---|
| winit adapter, private forwarder | `adapters/winit/src/platform_impl/unix.rs:25-27` |
| winit adapter, `WindowEvent::Moved` | `adapters/winit/src/platform_impl/unix.rs:48` |
| winit adapter, `WindowEvent::Resized` | `adapters/winit/src/platform_impl/unix.rs:66` |
| unix adapter, forward to live adapter | `adapters/unix/src/adapter.rs:187` |
| atspi-common, store into context | `adapters/atspi-common/src/adapter.rs:528-531` |
| C ABI export | `accesskit-c/src/unix.rs:60-67`, header `accesskit-c/include/accesskit.h:3022-3024` |

The C header repeats the same caveat at `accesskit-c/include/accesskit.h:3014-3021`.

### 2.2 `Adapter::update_window_focus_state`

Declaration, `adapters/unix/src/adapter.rs:222`:

```rust
pub fn update_window_focus_state(&mut self, is_focused: bool) {
```

Body, `adapters/unix/src/adapter.rs:223-237`: lock the state, then either store the
boolean in the `Inactive` or `Pending` variant or forward it with
`r#impl.update_window_focus_state(is_focused)`.

The forward target, `adapters/atspi-common/src/adapter.rs:541-545`, calls
`tree.update_host_focus_state_and_process_changes(is_focused, &mut handler)`. So
the boolean selects the host focus state on the tree root node, and the change
passes through the same change handler as a normal tree update.

Every caller in the reference tree:

| Caller | Location |
|---|---|
| winit adapter, `WindowEvent::Focused` | `adapters/winit/src/platform_impl/unix.rs:33-35` and `:72` |
| unix adapter, forward to live adapter | `adapters/unix/src/adapter.rs:235` |
| C ABI export | `accesskit-c/src/unix.rs:83-89`, header `accesskit-c/include/accesskit.h:3040-3041` |

The C SDL example shows the shape a ported application must reproduce.
`accesskit-c/examples/sdl/hello_world.c:171-183` calls
`accesskit_unix_adapter_update_window_focus_state` on the `UNIX` branch and nothing
else. On the Linux branch of adapter construction, `accesskit-c/examples/sdl/hello_world.c:107`
is `(void)window;`. The example never reports bounds on Linux at all. That is an
upstream gap in the example, and it is the reason the failure in section 2.1 is
silent.

### 2.3 The three-call contract for a ported application

| Call | When | If it is never called |
|---|---|---|
| `Adapter::new` | Once, at startup | Nothing is published. |
| `set_root_window_bounds` | On every move, resize, and at startup | Screen coordinates are wrong by the window origin. Silent. |
| `update_window_focus_state` | On every focus change | The tree never reports the host focus state. Silent. |

There is no fourth call. A ported application that uses an X11 toolkit must read
geometry from its toolkit. A ported application that uses a Wayland toolkit gets
no global position, which is what the caveat at
`adapters/unix/src/adapter.rs:171-172` says. Under Wayland the application can
still report size and focus, and should report a position of `(0, 0)` deliberately
rather than by accident.

---

## 3. The history: the code was never there

The brief asked which commit removed the X11 and Wayland code. It was never
removed, because it was never added. Evidence from the full history of the
checkout, all 711 commits on `main`, spanning 2021-06-22 to 2026-10-04:

```
$ git log --all --pretty=format: --name-only | sort -u | grep -iE 'x11|xcb|wayland|wl_'
```

No output, exit status 1. Not one path in the project, at any commit, has ever had
one of those four things in its name.

The first commit, `f8b166a` "Initial commit" on 2021-06-22, contains only two
files:

```
$ git ls-tree -r --name-only f8b166a
LICENSE
README.md
```

The only files ever deleted from the unix adapter's source tree are these four,
from `git log --all --diff-filter=D --pretty=format: --name-only | sort -u`:

```
platforms/unix/src/atspi/interfaces/events.rs
platforms/unix/src/atspi/object_ref.rs
platforms/unix/src/filters.rs
platforms/unix/src/node.rs
```

No X11 file and no Wayland file appears in that list.

### 3.1 Was the absence deliberate

The repository records no scope decision, because there was nothing to remove. The
three places that mention X11 or Wayland are all about the winit example window or
about a documentation caveat:

| Text | Location |
|---|---|
| "Mention caveats with window bounds under Wayland (#559)" | `adapters/unix/CHANGELOG.md:315` |
| "Fix winit examples window not showing up under Wayland (#625)" | `adapters/winit/CHANGELOG.md:344` |
| "Don't force winit's X11 and Wayland features to be enabled (#209)" | `adapters/winit/CHANGELOG.md:874` |

The only one that touches the adapter is the first. It is commit `b0cf01a26ded03d722818a193fa6902f69bbc102`,
dated 2025-05-06 23:36:56 +0200, subject "fix: Mention caveats with window bounds
under Wayland (#559)", one file changed, seven lines inserted. The full diff adds
only the doc comment and nothing else:

```
+    /// Set the bounds of the top-level window. The outer bounds contain any
+    /// window decoration and borders.
+    ///
+    /// # Caveats
+    ///
+    /// Since an application can not get the position of its window under
+    /// Wayland, calling this method only makes sense under X11.
     pub fn set_root_window_bounds(&mut self, outer: Rect, inner: Rect) {
```

The linked issue, `https://api.github.com/repos/AccessKit/accesskit/issues/559`,
is titled "fix: Mention caveats with window bounds under Wayland", is closed, was
created 2025-05-06, and its entire body is one line: "See
https://github.com/godotengine/godot/issues/106097".

**Answer for the reader who wants to know if an X11 adapter is coming back.** The
repository gives no signal that one is planned. There is no roadmap entry, no
issue reference and no changelog note. The port must not assume that an upstream X11
adapter will appear and can be mirrored later. If the port wants one, the port has
to build it, and section 4 prices that.

---

## 4. What reintroducing an X11 path would cost

This section is a cost statement, not a proposal. Nothing here is in scope for the
current milestone. `docs/40-plan.md` should treat it as a future milestone only if
a stakeholder asks for it.

### 4.1 The job an X11 path would have to do

Produce two facts that `docs/30-port-design.md` currently expects the application to
supply, namely screen-space geometry and focus state, plus the event stream that
keeps them current.

Minimum requests against the X server:

| Job | XCB request | C header on this host |
|---|---|---|
| Open a connection | `xcb_connect` | `/usr/include/xcb/xcb.h:571` |
| Check for failure | `xcb_connection_has_error` | `/usr/include/xcb/xcb.h:502` |
| Read the screen list | `xcb_setup_roots_iterator` | `/usr/include/xcb/xproto.h:5604` |
| Get window size | `xcb_get_geometry` | `/usr/include/xcb/xproto.h:6552` |
| Get the window origin in root coordinates | `xcb_translate_coordinates` | `/usr/include/xcb/xproto.h:8221` |
| Check whether a window is viewable | `xcb_get_window_attributes` | `/usr/include/xcb/xproto.h:6031` |
| Read the focus owner | `xcb_get_input_focus` | `/usr/include/xcb/xproto.h:8423` |
| Wait for replies | `xcb_wait_for_reply` | `/usr/include/xcb/xcbext.h:249` |
| Poll replies without blocking | `xcb_poll_for_reply` | `/usr/include/xcb/xcbext.h:276` |
| Close | `xcb_disconnect` | `/usr/include/xcb/xcb.h:530` |

The decorations problem is the part that costs real work. A window manager reparents
the client window, so the decoration frame is the parent. `xcb_query_tree` at
`/usr/include/xcb/xproto.h:6606` walks to the parent. That adds a second round trip
and a failure mode when no window manager is present.

### 4.2 What is on this host

`pkg-config` results, exact output:

| Package | `--modversion` | `--cflags` |
|---|---|---|
| `xcb` | `1.17.0` | (empty) |
| `x11-xcb` | `1.8.10` | (empty) |
| `xext` | `1.3.6` | (empty) |
| `wayland-client` | `1.24.0` | `-I/usr/include/wayland` |
| `wayland-scanner` | `1.24.0` | `-I/usr/include/wayland` |
| `wayland-cursor` | `1.24.0` | `-I/usr/include/wayland` |
| `xtst` | not found | not found |
| `xfixes` | not found | not found |
| `xi` | not found | not found |
| `xkbcommon` | not found | not found |
| `wayland-protocols` | not found | not found |

The empty `Cflags` for `xcb` means the headers are in the default search path. They
are. `pkg-config --cflags` returning empty is not evidence of absence, so the
headers were checked directly:

| Header | State |
|---|---|
| `/usr/include/X11/Xlib.h` | PRESENT |
| `/usr/include/X11/Xutil.h` | PRESENT |
| `/usr/include/xcb/xcb.h` | PRESENT |
| `/usr/include/xcb/xfixes.h` | PRESENT |
| `/usr/include/xcb/xinput.h` | PRESENT |
| `/usr/include/xcb/xkb.h` | PRESENT |
| `/usr/include/xcb/xtest.h` | PRESENT |
| `/usr/include/wayland/wayland-client.h` | PRESENT |
| `/usr/include/wayland/wayland-client-core.h` | PRESENT |
| `/usr/include/X11/extensions/XTest.h` | ABSENT |
| `/usr/include/X11/extensions/Xfixes.h` | ABSENT |
| `/usr/include/X11/extensions/XInput2.h` | ABSENT |
| `/usr/include/X11/extensions/XInput.h` | ABSENT |
| `/usr/include/X11/extensions/Xinerama.h` | ABSENT |
| `/usr/include/X11/extensions/XKB.h` | PRESENT |
| `/usr/include/xkbcommon/xkbcommon.h` | ABSENT |

The asymmetry still decides the implementation choice, but not for the reason it looks
like. Every XCB extension header is present. The matching Xlib extension headers are
absent except XKB.h. A `translate-c` binding to `libxcb` is therefore buildable on this
host today, and a binding to `libX11` plus `libXfixes` needs two headers added to the
include path. Those two headers are obtainable here with no root:
`docs/27-x11-headers-resolution.md` §2 takes them from the Nix sandbox store, copies them
into a writable scratch sysroot, and returns the verdict `WORKS`. A probe compiled, linked
and ran against them. Any X11 work should still use the XCB headers, because they are
already in the default search path.

There is also no `xdg-shell.xml` anywhere on this host, which is section 6.

### 4.3 Zig packages, in one paragraph

The house rule prefers a pinned Zig package over `translate-c`. For XCB no usable
package exists at Zig 0.16.0. `HaraldWik/xcb-zig` declares
`.minimum_zig_version = "0.16.0"` and `.name = .xcb`, but its `build.zig` discards
the module it creates (`_ = b.addModule("xcb", ...)`, so nothing is importable), it
requires a git submodule for the protocol XML, it has zero stars, and it compiles
only `core`, `bigreq`, `sync` and `xevie`, with `xfixes`, `xinput` and `xkb`
commented out. `incertia/libxzb` declares `.minimum_zig_version = "0.15.2"` but its
`src` is a single 755 byte file and its `build.zig` is the unmodified Zig template
with no `translate_c` and no scanner. `Midstall/xcb.zig` has no
`minimum_zig_version` field at all and pulls six tarballs including two from
`gitlab.freedesktop.org`. For X11 there is no candidate package at all: the search
for `x11 language:zig` on the GitHub API returns 66 repositories and all of them
are applications such as window managers, not libraries. **The honest rung for XCB
is rung 3, a `translate-c` binding to the system `libxcb`, because the C headers are
complete on this host and no Zig package can be imported at 0.16.0.**

---

## 5. Xvfb and the test environment

### 5.1 Is a private X server available

```
$ command -v Xvfb
/bin/Xvfb
$ command -v Xephyr
ABSENT
$ command -v Xwayland
ABSENT
$ command -v Xorg
/bin/Xorg
$ command -v xdotool
ABSENT
$ command -v xdpyinfo
ABSENT
$ command -v xprop
/bin/xprop
$ command -v xauth
/bin/xauth
```

No display is attached to this shell:

```
$ env | grep -E '^(DISPLAY|WAYLAND_DISPLAY|XDG_SESSION_TYPE|DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR)='
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/33156/bus
XDG_RUNTIME_DIR=/run/user/33156
XDG_SESSION_TYPE=tty
```

`DISPLAY` and `WAYLAND_DISPLAY` are unset. `XDG_SESSION_TYPE=tty` means there is no
session compositor.

### 5.2 Does starting one work

Yes. Exact command and output:

```
$ Xvfb :77 -screen 0 800x600x24 -nolisten tcp &
$ sleep 3; kill -0 $!  ; echo $?
yes
$ DISPLAY=:77 xprop -root
_XKB_RULES_NAMES(STRING) = "evdev", "pc105", "us", "", ""
```

The server started, took display 77, and answered a protocol request on its root
window. The `libEGL warning: failed to open /dev/dri/cardN: Permission denied`
lines in the server log are noise from a headless host with no GPU. The server was
killed afterwards and removed its own socket: `/tmp/.X11-unix` contained `X0` and
`X200` from before the test and no `X77` after it.

### 5.3 What Xvfb would make testable, honestly

**Nothing in the current plan needs it.** Sections 1 to 3 establish that no X11 code
will be written. `docs/13-atspi-protocol.md` covers the AT-SPI tree, which needs a
D-Bus bus, not an X server. Section 7 and section 8 cover a socket, not a display
server.

Xvfb becomes relevant in exactly one future case: if a milestone adds the X11 path
from section 4. Then it would prove three things that a transcript cannot:

1. That a real X server accepts the request sequence the port sends, with real
   reply sizes and real error codes. A scripted peer can only prove the port parses
   what the test wrote.
2. That `xcb_translate_coordinates` returns the origin a reparenting window manager
   would produce. Xvfb has no window manager, so it would not prove the decoration
   path. It would prove the undecorated path only.
3. That the focus answer from `xcb_get_input_focus` matches a real focus change. Xvfb
   has no window manager to move focus, so this needs a client that calls
   `xcb_set_input_focus`. `xtest` is absent from this host's `pkg-config` set, so there
   is no synthetic-input route out of the box. The library is obtainable from the Nix
   store if a future milestone needs it (`docs/27-x11-headers-resolution.md` §2).

**Recommendation.** Do not build X11 test infrastructure now. If section 4 is ever
scheduled, start the Xvfb server in that milestone and record the three limits above
in `docs/50-verification.md`, because two of the three cannot be closed by a
synthetic peer.

---

## 6. Wayland

### 6.1 What upstream touches

Nothing. Section 1.1 is the proof. The adapter never opens `wl_display_connect`,
never calls `wl_display_get_fd`, never binds `xdg_wm_base`, and never reads
`WAYLAND_DISPLAY`. The only occurrence of the word is the doc comment at
`adapters/unix/src/adapter.rs:172`, whose text explains that an application cannot
get its window position under Wayland.

That comment is a statement about the Wayland protocol, not about the adapter. It
tells an application that `set_root_window_bounds` is only useful under X11. The
adapter itself runs the same way under both display servers, because the adapter
does not know which one is present.

### 6.2 What a Wayland path would cost, if one were wanted

Same status as section 4: a cost statement, not a proposal.

A Wayland path cannot supply what the X11 path supplies. `xdg_wm_base` has no
global window position request, which is precisely what the caveat at
`adapters/unix/src/adapter.rs:171-172` says. A Wayland path could supply:

| Fact | Source protocol | Available to a plain client |
|---|---|---|
| Surface size | `wl_surface.configure` | Yes |
| Focus | `wl_keyboard.enter` and `wl_keyboard.leave` | Yes |
| Global position | none | No |
| Workspace and stacking order | `xdg_toplevel` state, compositor specific | No |

The client API that would have to be driven, with `path:line` into the headers on
this host:

| Symbol | Purpose | Location |
|---|---|---|
| `wl_display_connect` | Open the connection | `/usr/include/wayland/wayland-client-core.h:240` |
| `wl_display_get_fd` | Get the socket for the event loop, section 7 | `/usr/include/wayland/wayland-client-core.h:249` |
| `wl_display_dispatch_pending` | Decode queued events without blocking | `/usr/include/wayland/wayland-client-core.h:272` |
| `wl_display_dispatch` | Block until an event arrives | `/usr/include/wayland/wayland-client-core.h:252` |
| `wl_display_flush` | Push queued requests | `/usr/include/wayland/wayland-client-core.h:283` |
| `wl_display_roundtrip` | Sync barrier | `/usr/include/wayland/wayland-client-core.h:290` |
| `wl_display_get_error` | Read the connection error | `/usr/include/wayland/wayland-client-core.h:275` |
| `wl_display_disconnect` | Close | `/usr/include/wayland/wayland-client-core.h:246` |
| `wl_display_get_registry` | Enumerate globals | `/usr/include/wayland/wayland-client-protocol.h:1125` |
| `wl_registry_bind` | Bind `wl_compositor` | `/usr/include/wayland/wayland-client-protocol.h:1238` |
| `wl_registry_add_listener` | Receive global announcements | `/usr/include/wayland/wayland-client-protocol.h:1181` |
| `wl_compositor_create_surface` | Create the surface | `/usr/include/wayland/wayland-client-protocol.h:1354` |
| `wl_surface_commit` | Commit the surface state | `/usr/include/wayland/wayland-client-protocol.h:4140` |
| `wl_proxy_marshal_flags` | Send any request, the generic path | `/usr/include/wayland/wayland-client-core.h:133` |
| `wl_proxy_add_listener` | Receive any event, the generic path | `/usr/include/wayland/wayland-client-core.h:191` |

### 6.3 The blocker specific to Wayland: no protocol XML on this host

```
$ ls /usr/share/wayland/
wayland-scanner.mk
wayland.dtd
wayland.xml
$ ls /usr/share/wayland-protocols/
ls: cannot access '/usr/share/wayland-protocols/': No such file or directory
```

Only the core protocol is installed. `xdg-shell.xml` is absent, and a search of all
of `/usr/include/wayland` for `xdg_wm_base` or `xdg_surface` returns no match.
`pkg-config --modversion wayland-protocols` reports "not found".

Any Wayland work must therefore vendor `xdg-shell.xml` or take it from a package.
That is a dependency decision, not a code decision, and it belongs in
`local://zaccesskit-deps.md` when someone schedules the work. Do not schedule it
now.

---

## 7. The zio event loop question

This section is unchanged from the original brief and is more load bearing now,
because the transport the port actually needs is a socket.

### 7.1 Can zio await a raw file descriptor

**Yes.** The type that makes it possible is `zio.ev.NetPoll`, defined at
`~/zio/src/ev/completion.zig:2201`, with its constructor
at `~/zio/src/ev/completion.zig:2215`:

```zig
pub fn init(handle: Backend.NetHandle, event: Event) NetPoll {
    return .{
        .c = .init(.net_poll),
        .handle = handle,
        .event = event,
    };
}
```

`Event` is `enum { recv, send }` at `~/zio/src/ev/completion.zig:2210-2213`.
On Linux `Backend.NetHandle` is `net.fd_t`, which is a plain `i32`:
`~/zio/src/ev/backends/linux/io_uring.zig:82` declares
`pub const NetHandle = net.fd_t`, and `Backend` selects it at
`~/zio/src/ev/backends/linux.zig:38`.

So `NetPoll.init` takes any file descriptor, including one that libxcb, libwayland
or libdbus created. There is no ownership requirement.

There is a second type for pipes and regular files, `zio.ev.PipePoll` at
`~/zio/src/ev/completion.zig:2228`, with `init` at
`~/zio/src/ev/completion.zig:2242`. It takes an
`fs.fd_t`. For a socket, `NetPoll` is the correct one.

### 7.2 How a coroutine waits on it

`NetPoll` is a completion, so waiting needs a completion queue. `zio.CompletionQueue`
is exported at `~/zio/src/zio.zig:42`, and it accepts an
`ev.Completion` directly. The binding is the alias at
`~/zio/src/completion_queue.zig:73`:

```zig
const Completion = ev.Completion;
```

`submit` is `~/zio/src/completion_queue.zig:143`. It calls
`getCurrentExecutor().loopAdd(c)` on the submitter's own loop, so the completion
goes to the right loop without any explicit routing. `wait` is
`~/zio/src/completion_queue.zig:208` and it parks on a
futex word, so it yields the coroutine rather than the thread.

The whole pattern is:

```zig
var op = zio.ev.NetPoll.init(fd, .recv);   // readiness only, consumes nothing
var cq = zio.CompletionQueue.init();
defer cq.cancelAll(.keep);
try cq.submit(&op.c);
_ = try cq.wait();                          // coroutine suspends here
```

`zio.ev` itself is exported at `~/zio/src/zio.zig:107`.

**One gap to know about.** `waitForIo`, the single-completion blocking bridge at
`~/zio/src/common.zig:608`, is `pub` in `common.zig` but
`common` is not re-exported from the package root. `~/zio/src/zio.zig:46`
is `const common = @import("common.zig")`, a private import. A downstream package
therefore cannot call `waitForIo`. `CompletionQueue` is the supported replacement.
That is not a workaround, it is the intended route, and its own module comment at
`~/zio/src/completion_queue.zig:6-7` names `waitForIo` as
the single-operation alternative it exists to replace.

### 7.3 How the readiness edge becomes a wakeup

The chain, with `path:line` for each step:

1. `submitPoll` runs a zero timeout `std.posix.poll` on the descriptor and only
   parks if the probe says "not ready".
   `~/zio/src/ev/sockreg.zig:417-436`.
2. `park` takes the shard lock for the descriptor, registers this loop as the owner
   if there is none, and pushes the completion onto the owner loop's waiter queue.
   `~/zio/src/ev/sockreg.zig:214-268`.
3. `registerSocket` issues `epoll_ctl` with `EPOLLET`, the edge-triggered flag.
   `~/zio/src/ev/backends/linux/epoll.zig:536-551`.
4. The kernel returns the edge from `epoll_wait` inside `poll`.
   `~/zio/src/ev/backends/linux/epoll.zig:755`.
5. `service` walks the waiter queue for that descriptor and direction and completes
   the operations that finished.
   `~/zio/src/ev/sockreg.zig:273-299`.
6. The completion lands in the `CompletionQueue`, `ownerCallback` bumps the futex
   word, and `wait` returns.
   `~/zio/src/completion_queue.zig:143` and `:208`.

The single owner rule is stated in the module comment at `~/zio/src/ev/sockreg.zig:6-12`.
One loop registers a descriptor, for one direction, and services every waiter for
it. That means the port must pick **one** zio task to own a given socket. If two
tasks both await the same D-Bus descriptor, one becomes the owner and the other
migrates. The code handles it, but the port should not rely on the migration.

### 7.4 The nonblocking requirement, which is a real constraint

`submitIo`, the path that a `NetRecv` or `NetSend` takes, runs `checkCompletion`
inline, that is, it performs the actual syscall, before it ever considers parking.
See `~/zio/src/ev/sockreg.zig:366-383`. And `service`
runs each waiter's syscall under the shard lock and documents that syscall as
non-blocking at `~/zio/src/ev/sockreg.zig:271`, with
`.requeue => break, // drained to EAGAIN for this direction` at
`~/zio/src/ev/sockreg.zig:297`.

**Therefore the descriptor handed to zio must already be in non-blocking mode.**
`xcb_connect`, `wl_display_connect` and any D-Bus connect call leave the socket
blocking by default. The port must call `fcntl` with `O_NONBLOCK` before the first
read. If it does not, the optimistic probe at step 1 of section 7.3 stalls the
whole runtime thread.

### 7.5 Which thread runs the read

With `NetPoll`, no thread of your own is needed. A zio worker thread runs the
`epoll_wait`, and the coroutine that called `cq.wait()` is parked. That is the
recommended shape.

Two alternatives exist and both cost something:

| Shape | Cost |
|---|---|
| `zio.spawnBlocking`, `~/zio/src/runtime.zig:1506` | A dedicated OS thread per connection. It can call the blocking C API directly and push results into a `zio.Channel`. Wasteful for a port whose transport is one socket. |
| A private `zio.ev.Loop`, `~/zio/src/ev/loop.zig:523` with `run` at `:844` | A second event loop in the process, bridged to the runtime by hand through a callback. This is the model in `examples/ev_demo.zig`. Unnecessary when `CompletionQueue` is available. |

If the port binds to libwayland through `translate-c`, note that `wl_display_dispatch`
blocks by design and cannot be driven from a coroutine without a second thread.
Use `wl_display_dispatch_pending` plus a `wl_display_get_fd` readiness wait instead.
This is a real reason to prefer `wl_display_prepare_read` style code over the
blocking convenience function.

### 7.6 What `NetPoll` does not give you

`NetPoll` gives readiness only. It does not read. After it returns, the caller must
read with its own buffer. That is the correct arrangement for the D-Bus transport,
because libdbus and goose both own the read buffer.

If the port wants to read directly with zio instead, `zio.net.readBuf` is public at
`~/zio/src/net.zig:45` and takes a
`Backend.NetHandle`, aliased at `~/zio/src/net.zig:25`. It
builds an `ev.NetRecv` and waits on it. Do not mix it with a library that also reads
the same descriptor.

---

## 8. The D-Bus socket, which is the event source that matters

### 8.1 What upstream uses

`accesskit_unix` does not open a D-Bus socket itself. It hands socket work to
`zbus`. `adapters/unix/src/atspi/bus.rs:48-51` builds the accessibility-bus
connection from an address string, and `adapters/unix/src/context.rs:58-59` builds
the session-bus connection. Both go through `zbus`, whose `async-io` backend owns
its own reactor thread.

The address itself, `adapters/unix/src/atspi/bus.rs:43-46`:

```rust
let address = match var("AT_SPI_BUS_ADDRESS") {
    Ok(address) if !address.is_empty() => address,
    _ => BusProxy::new(session_bus).await?.get_address().await?,
};
```

This host has the environment variable unset, and a live session bus at
`unix:path=/run/user/33156/bus`. So the port must implement the same two-step
lookup: environment variable first, then the `org.a11y.Bus` object on the session
bus. `docs/13-atspi-protocol.md` covers the object and its `IsEnabled` property.

### 8.2 Confirming what goose exposes

The sibling agent's claim is confirmed. goose v3.3.0 at commit `8c6ee3a`, checked
out in `/tmp/scratch/goose`:

| Claim | Location | Verdict |
|---|---|---|
| goose has a `poll` backend | `/tmp/scratch/goose/src/connection.zig:122-125`, `pub const Backend = enum { threaded, poll }` | Confirmed |
| goose exposes a file descriptor for an external event loop | `/tmp/scratch/goose/src/connection.zig:291-294`, `pub fn getFd(self: *const Connection) std.posix.fd_t` with the comment "Returns the underlying socket file descriptor for integration with external event loops." | Confirmed |
| goose can drive readiness itself | `/tmp/scratch/goose/src/connection.zig:297`, `hasDataToRead`, which does a zero timeout `std.posix.poll` on `self.getFd()` at `:301-307` | Confirmed |
| goose can dispatch one message without blocking | `/tmp/scratch/goose/src/connection.zig:312`, `pub fn dispatch(self: *Connection) !bool` | Confirmed |
| goose has a dedicated accessibility bus type | `/tmp/scratch/goose/src/connection.zig:134`, `Accessibility` in `BusType` | Confirmed, and new information for this project |
| the `poll` backend refuses to run its own serve loop | `/tmp/scratch/goose/src/connection.zig:892-894`, `if (self.backend == .poll) return error.InvalidBackend;` | Confirmed |

`BusType.Accessibility` reads `AT_SPI_BUS_ADDRESS` first and, when it is unset, falls back
to a hard-coded path rather than to the session bus. At
`/tmp/scratch/goose/src/connection.zig:493-501` the arm reads
`if (vars.get("AT_SPI_BUS_ADDRESS")) |addr| socket_paths = .init(addr);`, and the else
branch at `:496-500` builds the socket name `bus_0`:
`allocPrint(allocator, "unix:path=/run/user/{d}/at-spi/bus_0", .{uid})`. There is no
session-bus lookup in that branch, so this is not the logic at `bus.rs:43-46`, which calls
`BusProxy::get_address()` on the session bus. The port owns that step.

The consequence is measured, not inferred. The real socket on this host is
`/run/user/33156/at-spi/bus` and the fallback names `bus_0`, so with the variable removed
the connect fails with `error.FileNotFound`
(`docs/26-goose-live-bus-probe.md`). Every entry point must set `AT_SPI_BUS_ADDRESS`.

### 8.3 What it means for the port

The two halves fit together exactly. goose hands out a descriptor and refuses to
poll it itself under the `poll` backend. zio can await any descriptor with
`NetPoll`. So the port has one socket and one owner:

```
goose Connection (backend = .poll)
    |  conn.getFd()              goose/src/connection.zig:292
    v
zio.ev.NetPoll.init(fd, .recv)   zio/src/ev/completion.zig:2215
    |  cq.submit / cq.wait       zio/src/completion_queue.zig:143 / :208
    v  readiness edge
conn.dispatch()                 goose/src/connection.zig:312
```

Three consequences the design wave must record.

1. **One descriptor, one owner task.** Section 7.3 applies. The port should run one
   zio task per D-Bus connection that owns the `NetPoll` and dispatches in a loop.
2. **goose must be set to `poll`, not `threaded`.** `Connection.init` at
   `/tmp/scratch/goose/src/connection.zig:469` defaults to
   `.threaded`, which starts its own worker threads. `initWithBackend` at `:474`
   takes the backend explicitly. Under `.threaded` there would be two readers on
   one socket.
3. **The descriptor must be non-blocking before the first `NetPoll`.** Section 7.4.
   goose's own `readVec` at `/tmp/scratch/goose/src/connection.zig:181`
   maps `recvmsg` returning `EAGAIN` to `error.WouldBlock`, so goose already
   expects a non-blocking descriptor. Whether goose sets `O_NONBLOCK` itself was not
   checked. `[INFERENCE]` The port must set it defensively, and `docs/30-port-design.md`
   should place the `fcntl` before the first submit.

### 8.4 Headless routes, with no display server

Three routes are available today, none of which needs X11 or Wayland.

| Route | Status on this host | What it proves |
|---|---|---|
| Throwaway D-Bus session | `/usr/bin/dbus-daemon` and `/usr/bin/dbus-run-session` both present | That `dbus-run-session -- <test>` gives the port a private bus. The bus address comes from `DBUS_SESSION_BUS_ADDRESS`, which goose already reads. |
| Throwaway accessibility bus | `at-spi-bus-launcher` and `at-spi2-registryd` under `/usr/libexec/at-spi2/` | That `BusType.Accessibility` resolves and that the port's `IsEnabled` wait works against a real launcher. |
| UNIX socket pair with a scripted peer | `bind ok True` from the Python probe in scratch, and a live AF_UNIX socket at `/run/user/33156/bus` | That the wire-format decoder accepts a hand-written message and that a malformed message produces the right error. |
| Recorded event transcript | No tooling needed | That a given byte sequence produces a given tree state. This is the only route that survives a change to the real launcher, so it is the one to commit. |

The Python probe, run in `/tmp/scratch/X11WaylandSurface`:

```
$ python3 -c "import socket,os;p='.../probe.sock';s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.bind(p);print('bind ok',os.path.exists(p));s.close();os.unlink(p)"
bind ok True
```

**Recommendation.** Build the transcript route first. It needs no daemon, no
socket, and no display server, and it is the route that survives a change to
`at-spi-bus-launcher`. Add the `dbus-run-session` route second, because it proves
the address lookup. Do not use Xvfb at all, for the reasons in section 5.3.

---

## 9. House rules

Each rule from `AGENTS.md` section 2, and how this subject sits against it.

| Rule | Status for this subject |
|---|---|
| `io` is threaded explicitly, never global | The port must pass `std.Io` into `goose.Connection.init`, which takes it at `goose/src/connection.zig:469`. The `io` from `Runtime.io()` at `zio/src/runtime.zig:2067` is the candidate. No global. |
| State is a parameter, not a capture | `NetPoll` holds the descriptor by value in the struct (`zio/src/ev/completion.zig:2204`). `CompletionQueue` is created per connection. No capture. |
| Event and platform logic is pure over decoded input | The transcript route in section 8.4 is the direct test of this rule. Decode a frame, produce a tree state, no I/O in between. |
| Allocators are parameters | `goose.Connection.init(allocator, ...)` takes one at `goose/src/connection.zig:469`. `zio.ev.NetPoll` allocates nothing. |
| Error sets are explicit | `NetPoll.Error` is `net.RecvError \|\| Cancelable` at `zio/src/ev/completion.zig:2207`. `CompletionQueue.wait` returns `(Cancelable \|\| Closeable)!*Completion` at `zio/src/completion_queue.zig:208`. Both are explicit. |
| Loops have fixed upper bounds | `select.zig:480` sets `const max_awaitables = 64`. `sockreg` uses 64 shards at `zio/src/ev/sockreg.zig:97`. The port has one loop with one socket, so the bound is one. |
| No backwards compatibility | The port exports the C ABI from `accesskit-c/include/accesskit.h` directly. There is no X11 or Wayland shape to preserve, because upstream has none. |

The one rule this subject fights is "event and platform logic is pure over decoded
input". A readiness wait is inherently impure. The fix is not to purity but to
separation: `NetPoll` owns the wait, and the decode function above it is pure.
`docs/30-port-design.md` should keep that line visible in the module layout.

---

## 10. Decisions this document hands to `docs/30-port-design.md`

| Number | Decision | Input |
|---|---|---|
| 1 | Ship no X11 code and no Wayland code in the first milestone. | Sections 1 and 3. |
| 2 | Require the application to supply window bounds, or make bounds a required constructor parameter. Do not leave it optional. | Section 2.1. The failure is silent. |
| 3 | Use goose with the `poll` backend, not `threaded`. | Section 8.3, item 2. |
| 4 | Await the goose descriptor with `zio.ev.NetPoll` through `zio.CompletionQueue`. | Sections 7.1 and 7.2. |
| 5 | Set `O_NONBLOCK` on the D-Bus descriptor before the first submit. | Section 7.4. |
| 6 | Run one owner task per connection, not several. | Section 7.3. |
| 7 | Do not start Xvfb, and do not plan X11 test infrastructure. | Section 5.3. |
| 8 | If an X11 path is ever scheduled, bind XCB, not Xlib, because the XCB extension headers are already in the default search path. The `Xfixes.h` and `XTest.h` gap is not a reason: both are obtainable on this host with no root, per `docs/27-x11-headers-resolution.md` §2, verdict `WORKS`. | Section 4.2. |
| 9 | If a Wayland path is ever scheduled, vendor `xdg-shell.xml`. It is not on this host. | Section 6.3. |
| 10 | Build the transcript replay route before any daemon-based test. | Section 8.4. |

Items 8 and 9 are contingent. Items 1 to 7 and 10 are not.
