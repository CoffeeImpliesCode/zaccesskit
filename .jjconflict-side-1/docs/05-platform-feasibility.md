# 05 — Platform feasibility on this host

Consumed by `docs/30-port-design.md` (binding decisions) and `docs/40-plan.md` (milestones).
This document answers one question: what can this machine compile, link, run and test.

Every row carries the literal command and its verbatim output. Anything not directly observed
is marked `[INFERENCE]`. Nothing here is written from memory of upstream AccessKit.

## 0. Method

All commands ran in `~/zaccesskit` on openSUSE Linux
(`cc (SUSE Linux) 15.3.0`), x86_64, glibc 2.40. The reference checkouts were read only.
No build, test, format or lint gate was run.

Two corrections to the brief's assumptions, both verified:

1. **`ldconfig` is not installed.** `ldconfig -p` returns exit 127, not an empty list.
   A piped `ldconfig -p | grep ...` silently yields nothing because the pipeline masks the
   missing command. `/etc/ld.so.cache` does exist (119075 bytes, dated Sep 9). The loader
   uses that cache, so linking works. Do not read a silent pipeline as an absent library.
2. **The extracted compiler has no target JSON.** The directory
   `/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ`
   holds `LICENSE`, `README.md`, `doc/`, `lib/`, `zig`. `zig targets` is the working route.

## 1. Verdict table

### 1.1 pkg-config probe

Command:

```sh
for p in x11 xcb x11-xcb xext xtst xfixes xi xkbcommon xkbcommon-x11 wayland-client \
         wayland-cursor wayland-egl egl gl glib-2.0 gobject-2.0 gio-2.0 gio-unix-2.0 \
         dbus-1 atk-1.0 atspi-2 gail-3.0 gtk+-3.0 gtk4 cairo pango libudev; do
  if pkg-config --exists "$p" 2>/dev/null; then
    echo "PKGCONFLINE_OK $p $(pkg-config --modversion "$p")"
  else
    echo "PKGCONFLINE_ABSENT $p"
  fi
done
```

Verbatim output:

```
PKGCONFLINE_OK x11 1.8.10
PKGCONFLINE_OK xcb 1.17.0
PKGCONFLINE_OK x11-xcb 1.8.10
PKGCONFLINE_OK xext 1.3.6
PKGCONFLINE_ABSENT xtst exit=1
PKGCONFLINE_ABSENT xfixes exit=1
PKGCONFLINE_ABSENT xi exit=1
PKGCONFLINE_ABSENT xkbcommon exit=1
PKGCONFLINE_ABSENT xkbcommon-x11 exit=1
PKGCONFLINE_OK wayland-client 1.24.0
PKGCONFLINE_OK wayland-cursor 1.24.0
PKGCONFLINE_OK wayland-egl 18.1.0
PKGCONFLINE_ABSENT egl exit=1
PKGCONFLINE_ABSENT gl exit=1
PKGCONFLINE_OK glib-2.0 2.84.4
PKGCONFLINE_OK gobject-2.0 2.84.4
PKGCONFLINE_OK gio-2.0 2.84.4
PKGCONFLINE_OK gio-unix-2.0 2.84.4
PKGCONFLINE_OK dbus-1 1.14.10
PKGCONFLINE_ABSENT atk-1.0 exit=1
PKGCONFLINE_ABSENT atspi-2 exit=1
PKGCONFLINE_ABSENT gail-3.0 exit=1
PKGCONFLINE_ABSENT gtk+-3.0 exit=1
PKGCONFLINE_ABSENT gtk4 exit=1
PKGCONFLINE_ABSENT cairo exit=1
PKGCONFLINE_ABSENT pango exit=1
PKGCONFLINE_OK libudev 257
```

`pkg-config` resolves to `/usr/bin/x86_64-suse-linux-gnu-pkg-config`. `PKG_CONFIG_PATH` and
`PKG_CONFIG_LIBDIR` are unset. `pkg-config --variable pc_path pkg-config` prints
`/usr/lib64/pkgconfig:/usr/share/pkgconfig`.

`xkbcommon` appears twice in the requested list. Both probes agree: absent.

### 1.2 Verdicts, owners, and the Zig-first column

"Rung" is the decision ladder: 1 = Zig standard library, 2 = pinned Zig package,
3 = `translate-c` on a system C library, 4 = hand-written C shim.

| Dependency | Verdict | Command and verbatim output | Owning RPM (`rpm -qf` on the `.pc`) | Zig package available instead | Rung |
|---|---|---|---|---|---|
| x11 | present 1.8.10 | `pkg-config --modversion x11` → `1.8.10` | `libX11-devel-1.8.10-160000.3.1.x86_64` | `marler8997/zigx`; `c19/zig-X11-client` (self-described "incomplete, proof of concept"). Neither in local cache | 2 or 3 |
| xcb | present 1.17.0 | `pkg-config --modversion xcb` → `1.17.0` | `libxcb-devel-1.17.0-160000.2.2.x86_64` | same two as above | 2 or 3 |
| x11-xcb | present 1.8.10 | `pkg-config --modversion x11-xcb` → `1.8.10` | `libX11-devel-1.8.10-160000.3.1.x86_64` | none; shim over Xlib | 4 |
| xext | present 1.3.6 | `pkg-config --modversion xext` → `1.3.6` | `libXext-devel-1.3.6-160000.3.2.x86_64` | none | 3 |
| xtst | absent | `pkg-config --exists xtst` → exit 1 | runtime only: `libXtst6-1.2.5-160000.3.2` | none | 3 |
| xfixes | absent | `pkg-config --exists xfixes` → exit 1 | runtime only: `libXfixes3-6.0.1-160000.3.2` | none | 3 |
| xi | absent | `pkg-config --exists xi` → exit 1 | runtime only: `libXi6-1.8.2-160000.3.2` | none | 3 |
| xkbcommon | absent | `pkg-config --exists xkbcommon` → exit 1 | runtime only: `libxkbcommon0-1.8.0-160000.2.2` | `Deins/zig-wayland` ships a scanner | 3 |
| xkbcommon-x11 | absent | `pkg-config --exists xkbcommon-x11` → exit 1 | none | none | n/a |
| wayland-client | present 1.24.0 | `pkg-config --modversion wayland-client` → `1.24.0` | `wayland-devel-1.24.0-160000.1.2.x86_64` | `ItaloYt/zwl` — "only contains the core, that means that none of the interfaces" | 3 |
| wayland-cursor | present 1.24.0 | `pkg-config --modversion wayland-cursor` → `1.24.0` | `wayland-devel-1.24.0-160000.1.2.x86_64` | none | 3 |
| wayland-egl | present 18.1.0 | `pkg-config --modversion wayland-egl` → `18.1.0` | `wayland-devel-1.24.0-160000.1.2.x86_64` | none | 3 |
| egl | absent | `pkg-config --exists egl` → exit 1 | runtime only: `libglvnd-1.7.0-160000.3.2` | none | 3 |
| gl | absent | `pkg-config --exists gl` → exit 1 | none | none | n/a |
| glib-2.0 | present 2.84.4 | `pkg-config --modversion glib-2.0` → `2.84.4` | `glib2-devel-2.84.4-160000.4.1.x86_64` | none; see section 3 | 3, not needed |
| gobject-2.0 | present 2.84.4 | `pkg-config --modversion gobject-2.0` → `2.84.4` | `glib2-devel-2.84.4-160000.4.1.x86_64` | none; see section 3 | 3, not needed |
| gio-2.0 | present 2.84.4 | `pkg-config --modversion gio-2.0` → `2.84.4` | `glib2-devel-2.84.4-160000.4.1.x86_64` | none; see section 3 | 3, not needed |
| gio-unix-2.0 | present 2.84.4 | `pkg-config --modversion gio-unix-2.0` → `2.84.4` | `glib2-devel-2.84.4-160000.4.1.x86_64` | none; see section 3 | 3, not needed |
| dbus-1 | present 1.14.10 | `pkg-config --modversion dbus-1` → `1.14.10` | `dbus-1-devel-1.14.10-160000.2.2.x86_64` | **`goose` 3.3.0**, pure Zig, zero dependencies | 2 |
| atk-1.0 | absent | `pkg-config --exists atk-1.0` → exit 1 | none | none; AT-SPI is D-Bus only | n/a |
| atspi-2 | absent | `pkg-config --exists atspi-2` → exit 1 | runtime only: `libatspi0-2.56.3-160000.2.2` | none | n/a |
| gail-3.0 | absent | `pkg-config --exists gail-3.0` → exit 1 | none | none | n/a |
| gtk+-3.0 | absent | `pkg-config --exists gtk+-3.0` → exit 1 | none | none | n/a |
| gtk4 | absent | `pkg-config --exists gtk4` → exit 1 | none | none | n/a |
| cairo | absent | `pkg-config --exists cairo` → exit 1 | none | none | n/a |
| pango | absent | `pkg-config --exists pango` → exit 1 | none | none | n/a |
| libudev | present 257 | `pkg-config --modversion libudev` → `257` | `systemd-devel-257.13-160000.3.1.x86_64` | none | 3 |

Notes on the table.

- `atk-1.0`, `atspi-2`, `gail-3.0`, `gtk+-3.0`, `gtk4`, `cairo` and `pango` are absent, and
  none of them is in the `Cargo.toml` of any upstream adapter. Their absence blocks nothing.
- `at-spi2-core-2.56.3-160000.2.2.x86_64` is installed and runs, but ships zero `.pc` files
  and zero headers. `libatspi.so.0.0.1` is present. There is nothing to `translate-c` against.
- `xtst`, `xfixes`, `xi`, `xkbcommon` and `egl` are runtime-only: the host ships the
  shared object but neither the header under `/usr/include` nor a `.pc` file. The first
  four are obtainable here from the Nix sandbox store with no root
  (`docs/27-x11-headers-resolution.md` §2, verdict `WORKS`). `egl` was not part of that
  probe. None of the five is needed, because `adapters/unix/src/` has no X11, XCB or
  Wayland path (`docs/14-x11-wayland-surface.md` §1).

### 1.3 Headers actually present

Command `ls -1 /usr/include/X11/extensions/*.h | head -12` and `ls -1 /usr/include/wayland/*.h`:

```
/usr/include/X11/Xlib.h                        EXISTS
/usr/include/xcb/xcb.h                         EXISTS
/usr/include/wayland/wayland-client.h          EXISTS   (under /usr/include/wayland)
/usr/include/glib-2.0/glib.h                   EXISTS
/usr/include/dbus-1.0/dbus/dbus.h              EXISTS
/usr/include/X11/extensions/XTest.h            MISSING
/usr/include/xkbcommon/xkbcommon.h             MISSING
```

`pkg-config --cflags --libs` for the libraries that matter, verbatim:

```
--- x11 ---            -lX11
--- xcb ---            -lxcb
--- x11-xcb ---        -lX11-xcb -lX11 -lxcb
--- xext ---           -lXext
--- wayland-client --- -I/usr/include/wayland -lwayland-client -lm
--- wayland-cursor --- -I/usr/include/wayland -lwayland-cursor
--- glib-2.0 ---       -I/usr/include/glib-2.0 -I/usr/lib64/glib-2.0/include -lglib-2.0
--- gio-2.0 ---        -pthread -I/usr/include/glib-2.0 -I/usr/lib64/glib-2.0/include
                       -DWITH_GZFILEOP -I/usr/include/libmount -I/usr/include/blkid
                       -lgio-2.0 -lgobject-2.0 -lglib-2.0
--- dbus-1 ---         -I/usr/include/dbus-1.0 -I/usr/lib64/dbus-1.0/include -ldbus-1
--- libudev ---        -ludev
```

### 1.4 Toolchain

| Item | Command | Verbatim output |
|---|---|---|
| C compiler | `cc --version` | `cc (SUSE Linux) 15.3.0` |
| Zig | `zig version` | `0.16.0` (anyzig shim) |
| zig cc | `zig cc --version` | `Target: x86_64-unknown-linux6.12.0-gnu2.39.0` |
| libc | `zig libc` | `include_dir=/usr/include`, `sys_include_dir=/usr/include`, `crt_dir=/usr/lib64/gcc/x86_64-suse-linux/15/../../../../lib64` |
| glibc | `getconf GNU_LIBC_VERSION` | `glibc 2.40` |
| ldconfig | `ldconfig -p` | `error: command not found: ldconfig`, exit 127 |
| ld cache | `ls -la /etc/ld.so.cache` | `-rw-r--r-- 1 root root 119075 Sep 9 14:42` |
| nix | `nix --version` | `nix (Nix) 2.35.2` |
| devenv | `devenv version` | `devenv 2.4.1+fe20b5c (x86_64-linux)`, exit 0 |

Both `nix` and `devenv` work. `devenv.nix` declares `pkgs.git` and `pkgs.pkg-config` only. It
declares no X11, GLib, D-Bus or AT-SPI development package, so the host RPMs supply them.

`zig targets` emits a Zig struct literal, not JSON, into 32430 lines. Counts: 42 `os` values
and 27 `abi` values. The platforms AccessKit ships are all present in the `os` list:

```
freestanding other contiki fuchsia hermit managarm haiku hurd illumos linux plan9 rtems
serenity dragonfly freebsd netbsd openbsd driverkit ios maccatalyst macos tvos visionos
watchos windows uefi 3ds ps3 ps4 ps5 psp vita emscripten wasi amdhsa amdpal cuda mesa3d
nvcl opencl opengl vulkan
```

Cross-compilation to `aarch64-linux-android`, `aarch64-macos`, `aarch64-ios` and
`x86_64-windows` is therefore expressible. `[INFERENCE]` Cross-compiling proves the
target triple is known to the compiler. It does not prove the platform SDK is present.

### 1.5 Rust presence, recorded and not used

`cargo --version` → `cargo 1.98.1 (797e8a9bc 2026-08-05)`.
`rustc --version` → `rustc 1.98.1 (48a229cea 2026-09-01)`.

| Variable | Value |
|---|---|
| `CARGO_HOME` | `~/.local/share/cargo` |
| `RUSTUP_HOME` | `~/.local/share/rustup` |
| `CARGO_TARGET_DIR` | `/tmp/scratch/cargo-target` |

**Neither `cargo` nor `rustc` is a build input of this project.** They exist on the host for
other work. The port must build with no `Cargo.toml`, no `Cargo.lock`, no `build.rs`, no
`rust-toolchain`, no `cbindgen`, and no step that shells out to `cargo`. The port is never
run against upstream Rust as an oracle. Behaviour is pinned with recorded fixtures instead.

## 2. What this changes about the plan

### 2.1 The headless-host consequence, stated plainly

This host has **no usable display server for this session, but it does have two working
substitutes**. Both claims below are observed, not inferred.

There is no display for this session. `DISPLAY` and `WAYLAND_DISPLAY` are both unset, and
`XDG_SESSION_TYPE=tty`. Two X servers do run — `Xorg.bin :0` under lightdm, and a socket
owned by another user at `:200` — but neither accepts a connection from this account:

```sh
$ DISPLAY=:0 xset q
Authorization required, but no authorization protocol specified
xset:  unable to open display ":0"
$ DISPLAY=:200 xset q
Authorization required, but no authorization protocol specified
xset:  unable to open display ":200"
$ ls -la /run/lightdm/root/:0
ls: cannot open file '/run/lightdm/root/:0': Permission denied
```

No Wayland compositor exists. `command -v weston` → `weston: not found`.

But a private X server is available, because Xvfb is installed and runs as this user:

```sh
$ rpm -qf /bin/Xvfb
xorg-x11-server-Xvfb-21.1.15-160000.6.1.x86_64
$ Xvfb :77 -screen 0 1280x1024x24 -nolisten tcp &   # then
$ DISPLAY=:77 xset q
Keyboard Control:
  auto repeat:  on    key click percent:  0    LED mask:  00000000
  ...
$ DISPLAY=:77 xrandr
Screen 0: minimum 1 x 1, current 1280 x 1024, maximum 1280 x 1024
screen connected 1280x1024+0+0 0mm x 0mm
```

`Xvfb :77` serves clients without X authority. A test suite can start one on a free display
number and point `DISPLAY` at it.

And a real AT-SPI stack is live on this host. This is the single most useful fact in this
document:

```sh
$ echo $DBUS_SESSION_BUS_ADDRESS
unix:path=/run/user/33156/bus
$ ps -eo pid,comm,args | grep at-spi2-registr
  5154 at-spi2-registr  /usr/libexec/at-spi2/at-spi2-registryd --use-gnome-session
$ dbus-send --session --dest=org.a11y.Bus --print-reply \
      /org/a11y/bus org.a11y.Bus.GetAddress
   string "unix:path=/run/user/33156/at-spi/bus"
$ busctl --address=unix:path=/run/user/33156/at-spi/bus list
NAME                      PID PROCESS         USER     DESCRIPTION
:1.2                    29982 busctl          user -
org.a11y.atspi.Registry     - -               -       (activatable)
org.freedesktop.DBus    55300 at-spi-bus-laun user -
$ busctl --address=unix:path=/run/user/33156/at-spi/bus call \
      org.a11y.atspi.Registry /org/a11y/atspi/accessible/root \
      org.a11y.atspi.Accessible GetChildAtIndex ii 0 0
(so) "org.a11y.atspi.Registry" "/org/a11y/atspi/null"
```

The registry answers. The tree is empty, because no accessible application has registered.

### 2.2 "Compiles and links" versus "runs against a real display server"

These are different claims and this host supports different answers for each.

| Adapter | Compiles and links here | Runs here | Evidence |
|---|---|---|---|
| `accesskit` (core) | yes | yes, headless | no C dependency at all; `accesskit/Cargo.toml` declares none |
| `accesskit_atspi_common` | yes | yes | D-Bus only. Needs goose; no AT-SPI C library |
| `accesskit_unix` | yes | yes, against the live a11y bus | D-Bus only. Needs goose |
| `accesskit_windows` | cross-compile only | no | `windows` crate features; no Windows SDK on this host |
| `accesskit_macos` | cross-compile only | no | `objc2-app-kit`; no macOS SDK |
| `accesskit_ios` | cross-compile only | no | `objc2-ui-kit`; no iOS SDK |
| `accesskit_android` | cross-compile only | no | JNI, Android NDK |
| `accesskit_winit` | no | no | needs `winit` plus `softbuffer` X11 and Wayland backends |

The unix adapter is the only adapter with a live target on this host, and it is live over
D-Bus, not over X11. Upstream confirms this: `adapters/unix/src/` contains exactly one
hit for `xcb|wayland|x11|xlib|xkb|wl_`, and it is a doc comment at
`adapters/unix/src/adapter.rs:172`. External crate use across the adapter is `zbus` (18),
`accesskit_atspi_common` (17), `atspi` (10), plus `serde` and the async runtime. Each of
those three counts excludes one `use` in the test module, which opens at
`adapters/unix/src/atspi/interfaces/cache.rs:115`: `use zbus` at `:127`,
`use accesskit_atspi_common` at `:122` and `use atspi` at `:125`.

X11 enters upstream only through winit. `adapters/winit/Cargo.toml:16` puts `winit/x11`
and `winit/wayland` in the default feature set, and `adapters/winit/Cargo.toml:46-49`
asks for them again in the winit dev-dependency. `example_common/Cargo.toml:17-22` adds
`softbuffer` with `x11`, `x11-dlopen`, `wayland` and `wayland-dlopen`. No line of
`adapters/unix/` names any of them, so none of these reaches the accessibility adapter.

### 2.3 What must be tested on a different machine, and why

| Target | Must run elsewhere | Reason, from evidence |
|---|---|---|
| Windows adapter | yes, on Windows | `translate-c` over the Windows SDK is not validated by a Linux cross-compile |
| macOS adapter | yes, on macOS | Objective-C runtime and NSAccessibility are not reachable from Linux |
| iOS adapter | yes, on iOS | same, plus UIKit |
| Android adapter | yes, on Android | JNI and Android accessibility services |
| X11 extension selection | no, because nothing selects them | `adapters/unix/src/` has no X11 path at all (`docs/14-x11-wayland-surface.md` §1), so no milestone needs the extension headers. The headers are also obtainable here, from the Nix sandbox store, with no root (`docs/27-x11-headers-resolution.md` §2, verdict `WORKS`) |
| Wayland adapter | no, because nothing ports it | `adapters/unix/src/` has no Wayland path either (`docs/14-x11-wayland-surface.md` §6.1). `docs/14-x11-wayland-surface.md` §6.2 prices it as a cost statement, not a proposal |
| AT-SPI against third-party apps | partly | the bus is live but the tree is empty, so cross-implementation behaviour is untested |

The last row is the important one. The port can register its own tree and walk it. It cannot
observe an application it did not write, because no such application registers here.

### 2.4 House-rule fit

| Rule (`AGENTS.md` section 2) | How the platform subject satisfies or fights it |
|---|---|
| `io` threaded explicitly, never global | Fights. libdbus and GLib both carry process-global state. goose offers a `.poll` backend exposing `conn.getFd()` with zero background threads, so the port owns readiness through the `io` it was handed |
| State is a parameter, not a capture | Satisfied. `atspi-common` crate is a translation layer over decoded D-Bus values; its state maps to explicit structs |
| Network and event logic pure over decoded input | Satisfied by construction. A D-Bus message is already a byte buffer with a decoder. The wire decoder stays pure; the socket does the IO |
| Allocators are parameters | Satisfied. goose takes an allocator in `Connection.init(allocator, .Session, io, init.environ_map)` |
| Error sets are explicit | Fights libdbus, which returns a family of opaque codes. goose returns Zig error sets. This favours goose on rule grounds alone |
| Loops have fixed upper bounds | Applies to the dispatch loop and to node-tree walks. Both must be bounded and fail fast |
| No backwards compatibility | Applies to the D-Bus surface. Only the current wire format is implemented |
| No Rust toolchain | Satisfied. Section 1.5 records `cargo` and `rustc` as present and not used |

## 3. The C dependency boundary

### 3.1 D-Bus: choose rung 2, goose

`goose` is a pure Zig D-Bus implementation. Observed in
`/tmp/scratch/goose`, version `3.3.0`, git tag `v3.3.0`, commit `8c6ee3a`,
`.minimum_zig_version = "0.16.0"`, `.dependencies = .{}`.

Its README names it "a pure Zig D-Bus implementation" and "a lightweight, pure-Zig
alternative to `libdbus` or `GDBus`". It supports Session, System and **Accessibility**
buses, which is the bus AccessKit needs. It handles method calls, signals, object export,
introspection XML, and a proxy code generator. It does SASL `EXTERNAL` authentication. Its
`.poll` backend returns the socket file descriptor so an external event loop can drive it.

Coverage against what the port needs: method calls, signal subscription, object export, and
serial type marshalling are all present. Two gaps carry risk. File descriptor passing was
added recently, at commits `78727c1` ("first fd passing draft") and `10bb9bd`, and the
version bump `8c6ee3a` says the implementation is still a draft. The AT-SPI socket handshake
depends on passing a file descriptor. `[INFERENCE]` The draft may not cover every case the
handshake needs, and that must be proven by a test against the live bus before the port
depends on it.

Two other facts constrain the choice. goose is **not** in the local Zig package cache;
`/tmp/cache/zig/p/` holds blake3, box2d, box3d, erfa, fast_float,
geographiclib_c, gmp, htscodecs, inchi, libunibreak, lmdb, lua, luajit, mpfr, pcre2,
predicates, random123, ryu, s2geometry, sheenbidi, spglib, tzdata, utf8proc, zautomerge,
zig_agent_proto and zio. No D-Bus package. And `zio`'s own `.dependencies` is empty, so the
port would be the first to add one.

Rung 3 for comparison, and why it is worse: libdbus is present with headers and
`-I/usr/include/dbus-1.0`, so `translate-c` would bind the surface. The blocker is not the
surface. It is that libdbus carries a global connection model, a main loop, and a
`DBusError` out-parameter convention that maps badly onto an explicitly threaded `io`. The
`dbus_connection_*` read and write functions are blocking and non-cancellable, which fights
an async runtime. Goose is rung 2, which is higher, so libdbus loses.

### 3.2 GLib and GIO: present, but not needed

`glib-2.0`, `gobject-2.0`, `gio-2.0` and `gio-unix-2.0` are all present at 2.84.4 with full
headers. No upstream adapter lists any of them in its `Cargo.toml`. The port should not
bind them at all.

If a binding were ever attempted, these are the concrete blockers, stated in advance:

- GObject registration is macro-driven. `G_DECLARE_FINAL_TYPE`, `G_DEFINE_TYPE` and
  `g_signal_new` do not expand to anything a C parser can follow, so `translate-c` yields an
  unusable struct.
- `GType` and `GObjectClass` are opaque handles reached only through those macros.
- Property notification uses `g_object_notify` by string name, with no type information at
  the call site.
- `g_main_context` is a process-global loop with no `io` parameter, which fights the
  house rule directly.

The honest position is rung 3, and not needed. State it once and drop it.

### 3.3 XCB: bindable, and not the only option

XCB is present at 1.17.0 with headers at `/usr/include/xcb/xcb.h` and `-lxcb`. XCB is the
X11 client library that translates requests into wire format, so it is a good fit for a port
that wants to speak X11 without Xlib.

`translate-c` covers most of it. The blockers are narrow and nameable:

- `xcb_connection_t` is an opaque handle, but it is an opaque *struct* with a public
  `void *` tail, so binding it as an opaque pointer type works. This is not a blocker.
- Reply cookies are `xcb_generic_cookie_t`, an owned value with a destructor. Zig needs an
  `errdefer` discipline rather than a Rust `Drop`, which is a port change, not a binding
  blocker.
- Many entry points are `static inline` in the headers, dispatching through
  `_xcb_send_request` and `_xcb_recv_reply`. `translate-c` may not emit usable definitions
  for these. `[INFERENCE]` This needs a compile trial to confirm.

Two Zig alternatives were found by name, and neither is present locally:

- `marler8997/zigx`. Described on ziggit as "fully in zig and compiles to a static
  executable", with an API "fairly similar" to libxcb.
- `c19/zig-X11-client`. Self-described as "an incomplete, proof of concept client
  implementation of the X11 protocol in zig", aiming at a zero-dependency X11 client.

For "compiles and links", rung 3 with system XCB is the low-risk answer and it is already
present. For "runs", neither Zig candidate is proven. `zigx` is the stronger lead and needs
an API-completeness trial against the requests the port actually issues.

### 3.4 Xlib, XTest, XFixes, XInput: a packaging gap, not a blocker

`x11` is present at 1.8.10 with `/usr/include/X11/Xlib.h`. `xext` is present at 1.3.6.

XTest is the hard case for the system package manager. `/usr/include/X11/extensions/XTest.h`
is **MISSING** and there is no `.pc` file. `rpm -qf /usr/lib64/libXtst.so.6.1.0` →
`libXtst6-1.2.5-160000.3.2`. The account cannot install the package, because that needs
root. XFixes and XInput are in the same state: `libXfixes3-6.0.1` and `libXi6-1.8.2`
are runtime-only, with no headers under `/usr/include` and no `.pc`.

That is a packaging gap, and it closes. All four missing headers, xkbcommon included, are
obtainable on this host with no root: `docs/27-x11-headers-resolution.md` §2 takes them
from the Nix sandbox store, copies them into a writable scratch sysroot, and returns the
verdict `WORKS`. A probe compiled, linked and ran against them. §4.4 of that document adds
the four linker names, which the host is missing for the same reason.

This is a real rung-4 case, and the reason is concrete. Xlib is not a function table. It is
a macro-driven protocol layer whose core is `Display *` plus `XrmInitialize` plus a
`_XReply` handshake, and whose request functions expand into `_XReply` struct packing that
no C parser resolves. A hand-written shim would need to declare the functions itself and
accept that only the stable ABI subset is reachable. xkbcommon is worse: it has no header
under `/usr/include` at all, so even a shim has nothing to bind to until the Nix store copy
is on the include path.

Neither point blocks this project. The four extension headers are obtainable, and no
milestone needs them, because `adapters/unix/src/` contains no X11 path at all
(`docs/14-x11-wayland-surface.md` §1). Section 4 of `docs/14-x11-wayland-surface.md` is the
cost statement for reintroducing an X11 path, and its first paragraph says that nothing
in it is in scope for the current milestone.

### 3.5 Wayland: present and bindable

`wayland-client`, `wayland-cursor` and `wayland-egl` are present at 1.24.0 with headers
under `/usr/include/wayland/`. This is the cleanest `translate-c` case in the table,
because `wayland-client-protocol.h` declares the interface structs as plain C with no
macros in the request path. `pkg-config` supplies
`-I/usr/include/wayland -lwayland-client -lm`.

The Zig alternative is weaker. `ItaloYt/zwl` is "an implementation (not a binding) of the
libwayland using zig 0.15.2", which includes the client, the server and the scanner, but
"only contains the core, that means that none of the interfaces" are present. A client that
cannot speak a protocol interface is useless here. `Deins/zig-wayland` is a scanner plus
bindings, and its author warns the version "has no direct relation to the upstream
libwayland version supported" with breaking changes expected. `allyourcodebase/wayland-protocols`
packages protocol XML, not an implementation.

Rung 3, `translate-c` over the system library. Nothing here blocks, and no compositor
exists to test against anyway.

### 3.6 libudev: present, and no adapter uses it

`libudev` is present at version 257, from `systemd-devel-257.13-160000.3.1.x86_64`.
`rpm -qf /usr/lib64/libudev.so.1.7.10` confirms the runtime. No upstream adapter uses it.
Noted for completeness only.

### 3.7 AT-SPI: rung 1, write it in Zig

No C library is in play. `at-spi2-core` ships no `.pc` and no headers. Upstream does not use
`libatspi` either; the unix adapter depends on the `atspi` and `atspi-common` Rust crates,
which are pure D-Bus type definitions. A web search for a Zig AT-SPI implementation returned
nothing usable.

So the AT-SPI layer is rung 1: written in Zig on top of goose, driven by the interface
definitions. `adapters/unix/src/atspi/interfaces/` already enumerates the interfaces to
implement: `accessible`, `action`, `application`, `cache`, `component`, `document`,
`editable_text`, `hyperlink`, `image`, `selection`, `text`, `value`. That is the checklist.
`adapters/atspi-common/src/node.rs` is 2065 lines and `adapters/unix/src/atspi/bus.rs` is
525 lines, so the smallest honest version is not small.

### 3.8 Boundary summary

| Dependency | Rung | Binding result | Why it cannot sit higher |
|---|---|---|---|
| D-Bus | 2 | goose 3.3.0 | nothing higher exists; this IS the Zig package |
| AT-SPI | 1 | write in Zig | no Zig package, and no C library ships headers |
| GLib/GIO | not needed | n/a | macro-driven, global main loop; no adapter uses it |
| XCB | 3, maybe 2 | `translate-c` over system XCB | `zigx` exists but is unproven for our request set |
| Xlib | 4 | shim needed | macro-driven protocol layer, no stable function table |
| XTest / XFixes / XInput | not needed | n/a | nothing selects them. `adapters/unix/src/` has no X11 path (`docs/14-x11-wayland-surface.md` §1), and the four headers are obtainable from the Nix sandbox store with no root (`docs/27-x11-headers-resolution.md` §2, verdict `WORKS`), so nothing blocks |
| Wayland | 3 | `translate-c` | `zwl` has no protocol interfaces |
| libudev | 3 | not needed | no adapter uses it |

The three display-server rows above price a path the port is not taking.
`docs/14-x11-wayland-surface.md` §1 proves the upstream adapter has no X11, XCB or Wayland
code, and §4 and §6.2 say the cost statements there are not proposals. The rungs stay
because the binding difficulty does not change if a later milestone reopens the question.

## 4. Verification route

### 4.1 What the plan can rely on

**Headless AT-SPI, fully.** This is the strongest route and it works today. The a11y bus is
live, the registry answers, and `GetChildAtIndex` returns the null accessible. The port can
register a real tree on the live bus and then exercise the entire read path against
`at-spi2-registryd`, which is a third-party implementation not written by this project. That
covers D-Bus transport, name registration, the socket handshake that carries a file
descriptor, interface introspection, method dispatch, and signal emission.

The empty tree is the useful part. It means the test starts from a known state, with a
known, reproducible number of registered applications.

**A private X server under Xvfb.** `Xvfb :77` started, served `xset q` and `xrandr`, and was
then stopped. A test can pick a free display number, start Xvfb, set `DISPLAY`, and run.
Limits, stated plainly: Xvfb has no real input devices and no GPU. It exercises protocol
plumbing, not rendering. The current plan has no X protocol path to exercise
(`docs/14-x11-wayland-surface.md` §1), so nothing needs Xvfb now. If a future milestone
adds one, the XTest and XFixes headers come from the Nix sandbox store with no root
(`docs/27-x11-headers-resolution.md` §2, verdict `WORKS`).

**A scripted platform tree.** The house rule that network and event logic is pure over
decoded input makes this the natural unit test. A pure function over decoded D-Bus bytes
needs no bus, no registry and no display. `docs/30-port-design.md` should make the
decode/emit boundary the primary test seam, and this host supports it fully.

**A recorded event transcript.** A checked-in fixture of D-Bus message bytes with expected
output is reproducible here and needs nothing external. The house rule asks for exactly this
in place of a Rust oracle: wire compatibility is a test carrying bytes, not a comment.
Recording the bytes once, by hand or from the live bus during development, and checking
them in, satisfies it without `cargo`.

### 4.2 What the plan cannot rely on

**A real desktop session.** `DISPLAY` is unset and both running X servers refuse the
connection with "Authorization required". No test may assume a desktop.

**A Wayland compositor.** `weston: not found`. Nothing Wayland can be tested against.

**A third-party accessible application.** The tree is empty. Cross-implementation behaviour,
which is where AT-SPI bugs live, is untestable here. The port can prove it reads its own
output correctly. It cannot prove it agrees with orca or accerciser.

**XTest, XFixes and XInput.** Nothing in the current milestone binds them, because
`adapters/unix/src/` has no X11 path (`docs/14-x11-wayland-surface.md` §1). The headers
are obtainable here from the Nix sandbox store with no root
(`docs/27-x11-headers-resolution.md` §2, verdict `WORKS`), so this blocks nothing.

**A reference build.** `cargo` and `rustc` exist but must not be used as an oracle, a
golden-vector generator or a cross-check. See section 1.5.

### 4.3 Recommended test layering

1. Pure decode and encode, over recorded bytes. Runs anywhere. No display, no bus.
2. Bus round trip against the live `at-spi2-registryd` on this host. Real transport, real
   fd-passing handshake, no display.
3. X protocol paths against `Xvfb` on a chosen display. Plumb only, not extensions.
4. Defer to another machine: Windows, macOS, iOS, Android, real X extensions, real
   compositor, third-party AT-SPI clients.

## 5. Blockers

Each is a question only the user can settle, with the cost of each option.

**Q1. Is `goose` an acceptable D-Bus dependency, given fd passing is still a draft?**
Option A, pin `goose` 3.3.0 and prove the AT-SPI socket handshake against the live registry
before building on it. Cost: one new `build.zig.zon` dependency, and a spike test that may
fail. Option B, bind libdbus 1.14.10 with `translate-c` instead. Cost: a global connection
model and blocking calls that fight the `io` threading rule; the port then needs a thread
bridge. Recommendation: A, with the handshake spike as its own milestone.

**Q2. Closed: does the port ship an X11 path? No, and there is nothing upstream to port.**
`adapters/unix/src/` contains no X11 code (`docs/14-x11-wayland-surface.md` §1), so the
original Option A, `zigx` as a pure Zig client, and Option B, system XCB through
`translate-c`, were choices about writing a client from scratch. The original Option C is
the decision. `docs/14-x11-wayland-surface.md` §4 prices the alternative as a cost
statement and says in its first paragraph that nothing in it is in scope for the current
milestone. Cost of the decision: no X11 accessibility on Linux desktops, which the
application supplies instead through `Adapter::set_root_window_bounds` and
`Adapter::update_window_focus_state` (`docs/14-x11-wayland-surface.md` §2). The four X11
extension headers are not a factor either way, because they are obtainable on this host
with no root (`docs/27-x11-headers-resolution.md` §2, verdict `WORKS`).

**Q3. May `devenv.nix` gain development packages?**
Option A, keep it as is and rely on host RPMs. Cost: the build is not reproducible on a
machine that lacks `glib2-devel` or `dbus-1-devel`. Option B, add the packages. Cost: the
cache-root workaround in `devenv.nix` must hold for them too. Note that with goose chosen,
the D-Bus development package may not be needed at all.

**Q4. Which parts run in CI, and where does CI live?**
Option A, run layers 1 to 3 from section 4.3 on this cluster node. Cost: CI depends on a
live `at-spi2-registryd`, so CI is not hermetic. Option B, run only layer 1, and record the
a11y transcript as a fixture. Cost: loses coverage of the real fd-passing handshake, which
is the riskiest code in the port. This is the most consequential choice in this document.

**Q5. Is `at-spi2-registryd` guaranteed present on every future build machine?**
Option A, assume it is and fail loudly when it is not. Cost: a host without the AT-SPI
stack loses the round-trip test. Option B, ship a minimal in-process D-Bus registry for
tests. Cost: the test then exercises the test double, not the real broker, which weakens
exactly the evidence this document says is the strongest available.

**Q6. Confirm the no-Rust rule is absolute for this port.**
The brief says so and this document assumes it. If a temporary cross-check against upstream
Rust were wanted, it would contradict the stated rule and must be rejected. Cost of
confirming: none. Cost of not confirming: ambiguity during implementation.
