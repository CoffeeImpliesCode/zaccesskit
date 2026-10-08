# 07 — The Zig ecosystem, searched and measured

**Consumed by `docs/30-port-design.md`**, which binds each dependency to a rung
of the ladder, and by `docs/40-plan.md`, which orders the milestones that add
them.

## How to read this document

Every row in section 2 comes from a `build.zig.zon` that was read in a clone.
The clone path is given in the table. Line counts come from one command over
the whole clone, described in section 1.6. The I/O model column comes from a
`grep` for `std.Io` over `**/*.zig`, also described in section 1.6.

A claim that came from running a command gives the command and its output. A
claim that is an inference is marked `[INFERENCE]`. A claim I did not check is
marked `UNVERIFIED`. There is no third kind.

The compiler is Zig 0.16.0. `zig version` on this host is an anyzig shim; it
prints `0.16.0` and resolves to
`/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ`
`[OBSERVED: zig version]`.

Scratch for this document is under
`/tmp/scratch/ZigEcosystem/`. Nothing outside that directory
was written.

## 0. The short version

| Question | Answer |
|---|---|
| Is there a better D-Bus package than goose at Zig 0.16.0? | No. `LilithSemi/dbus.zig` is broader but has no `std.Io`. goose stays. |
| Does goose cover the whole AT-SPI path? | No. Three gaps are listed in section 3.1. |
| X11 | `baverman/zix11` 0.9.0 is the only pure-Zig X11 request client with `std.Io`. Rung 2. |
| XCB | `HaraldWik/xcb-zig` fetches but generates only core, bigreq, sync and xevie. Rung 3 for xfixes and xkb. |
| Wayland and xdg-shell | No pure-Zig client exists. `ifreund/zig-wayland` generates Zig but links `libwayland-client`. Rung 3. |
| EGL | No Zig package at all beyond `AshishBhattarai/egl-headers` (1 star, headers only). Rung 3. |
| OpenGL | `zig-gamedev/zopengl` has the loader; `ziglibs/zgl` does not. Rung 2. |
| Main loop | `zio` 0.18.0 is already chosen. Rung 2. |
| XKB | `LilithSemi/xkbcommon.zig` is pure Zig and parses the X11 wire replies. Rung 2. |
| Unicode property table | Not needed. AccessKit uses `char::len_utf16` and nothing else. Rung 1. |
| AT-SPI data types | No Zig package exists. Write them from the D-Bus XML. Rung 1. |
| Windows UI Automation | Zig ships the MinGW UIA headers. `translate-c` works with no SDK. Rung 3. |
| macOS accessibility | Objective-C only upstream. Needs the SDK. Rung 3, UNVERIFIED here. |

## 1. Method

### 1.1 What was searched

Four indexes. Each one is named with the exact query, so the list can be
repeated.

| Index | Endpoint | Query form | Result size seen |
|---|---|---|---|
| GitHub repository search | `https://api.github.com/search/repositories` | `q=<term>+language:zig` | 17 for `dbus`, 66 for `x11`, 11 for `xcb`, 171 for `wayland` |
| GitHub repository search | `https://api.github.com/search/repositories` | `q=<terms>` with no language filter | 13 for `accessibility language:zig`, 0 for `cocoa accessibility language:zig`, 0 for `ui automation windows language:zig` |
| Zigistry | `https://api.zigistry.dev/search/packages/` | `?q=<term>&page=1&per_page=25&sort=stars&dir=desc` | 8 for `dbus`, 27 for `x11`, 2 for `xcb`, 13 for `wayland`, 5 for `egl`, 30 for `opengl`, 1 for `xkb`, 43 for `unicode`, 72 for `accessibility`, 0 for `atspi` |
| Zig fetch registry | `zig fetch --global-cache-dir <scratch> <url>` | one call per candidate | 24 of the 27 attempted succeeded |
| pkg.machengine.org | `https://pkg.machengine.org/zig/` | not a package index. See section 1.4. | 404 |

### 1.2 GitHub search API: the exact calls

The GitHub CLI was authenticated, so the rate limit was 5000 requests per hour
for the core API and 30 per minute for search. Every call below used the exact
query string shown.

```
gh api "search/repositories?q=<urlencoded query>&per_page=30&page=1"
```

Queries run, in this order:

```
dbus language:zig
x11 language:zig
xcb language:zig
wayland language:zig
xdg-shell language:zig
egl language:zig
opengl language:zig
xkb language:zig
atspi language:zig
accessibility language:zig
event loop epoll zig
eventloop language:zig
unicode normalization language:zig
utf8 language:zig
epoll language:zig
zbus language:zig
cocoa accessibility language:zig
ui automation windows language:zig
glfw language:zig
gir glib introspection language:zig
xdg-shell zig
wayland scanner language:zig
egl.zig
egl opengl bindings zig
khronos language:zig
windows uia zig
objective-c language:zig
corefoundation language:zig
```

Two zero results matter and are recorded because they close off a search:
`atspi language:zig` returned `total_count = 0`, and
`ui automation windows language:zig` returned `total_count = 0`
`[OBSERVED: gh api search/repositories]`.

The full call log is at
`/tmp/scratch/ZigEcosystem/gh-search.log`.

### 1.3 Zigistry: how the endpoint was found

Zigistry is a client-rendered SvelteKit application. `curl` on any page
returns the same 4505-byte shell, with no package data
`[OBSERVED: curl -sSL https://zigistry.dev/]`. The JSON data source was found
by driving the page in a headless Chromium tab and reading the network log.

```
GET https://zigistry.dev/search          # loaded in a headless Chromium tab
# network log contained:
GET https://api.zigistry.dev/search/packages/?q=*&page=1&per_page=12&sort=stars&dir=desc
GET https://api.zigistry.dev/search/programs/?q=*&page=1&per_page=12&sort=stars&dir=desc
```

The trailing slash on `/packages/` matters. Without it the host answers
`301` to `/packages/` and the query string is dropped
`[OBSERVED: curl -sS -D - "https://api.zigistry.dev/packages?q=wayland"]` shows
`HTTP/2 301` and `location: /packages/`. The JSON response shape is
`{time_took_to_search_ns, total_pages, per_page, page, total, items}`.

The exact Zigistry queries run were:

```
GET https://api.zigistry.dev/search/packages/?q=dbus&page=1&per_page=25&sort=stars&dir=desc
GET https://api.zigistry.dev/search/packages/?q=x11&page=1&per_page=25&sort=stars&dir=desc
GET https://api.zigistry.dev/search/packages/?q=xcb&page=1&per_page=25&sort=stars&dir=desc
GET https://api.zigistry.dev/search/packages/?q=xdg-shell&page=1&per_page=25&sort=stars&dir=desc
GET https://api.zigistry.dev/search/packages/?q=wayland&page=1&per_page=25&sort=stars&dir=desc
GET https://api.zigistry.dev/search/packages/?q=egl&page=1&per_page=25&sort=stars&dir=desc
GET https://api.zigistry.dev/search/packages/?q=opengl&page=1&per_page=25&sort=stars&dir=desc
GET https://api.zigistry.dev/search/packages/?q=xkb&page=1&per_page=25&sort=stars&dir=desc
GET https://api.zigistry.dev/search/packages/?q=utf8&page=1&per_page=25&sort=stars&dir=desc
GET https://api.zigistry.dev/search/packages/?q=unicode&page=1&per_page=25&sort=stars&dir=desc
GET https://api.zigistry.dev/search/packages/?q=accessibility&page=1&per_page=25&sort=stars&dir=desc
GET https://api.zigistry.dev/search/packages/?q=atspi&page=1&per_page=25&sort=stars&dir=desc
GET https://api.zigistry.dev/search/packages/?q=event%20loop&page=1&per_page=25&sort=stars&dir=desc
GET https://api.zigistry.dev/search/packages/?q=epoll&page=1&per_page=25&sort=stars&dir=desc
GET https://api.zigistry.dev/search/packages/?q=glfw&page=1&per_page=25&sort=stars&dir=desc
GET https://api.zigistry.dev/search/packages/?q=zbus&page=1&per_page=25&sort=stars&dir=desc
```

One query failed at the server and was retried with the same result:
`q=xdg-shell` returned `{"error": "Problem with server."}`
`[OBSERVED: curl -sSL "https://api.zigistry.dev/search/packages/?q=xdg-shell&..."]`.

Zigistry indexes only repositories that opt in. It carries a `minimum_zig_version`
field per package, taken from the repository `build.zig.zon`
`[OBSERVED: items[].minimum_zig_version in the JSON]`.

### 1.4 pkg.machengine.org is not a package index

The assignment named `https://pkg.machengine.org/zig/` as a package index. It
is not. It is a Zig **toolchain** mirror that rewrites `ziglang.org/builds` URLs.
Observed:

```
$ curl -sSL -w "\n[HTTP %{http_code} final=%{url_effective}]\n" https://pkg.machengine.org/zig/
Not Found
[HTTP 404 final=https://pkg.hexops.org/zig/]

$ curl -sSL https://pkg.machengine.org/
<h1 style="margin-bottom: 0.25rem;">pkg.hexops.org</h1>
<strong ...><em>a Zig <a href="https://code.hexops.org/hexops/pkgmirror">pkgmirror</a></em></strong>
<h3 style="margin-top: 2rem;">Zig toolchain downloads</h3>
Download Zig toolchains by rewriting the URL as follows:
https://ziglang.org/builds/$FILE -> https://pkg.hexops.org/zig/$FILE
```

There is no package catalogue at that host, so it contributed nothing to the
candidate list. The index that carries Zig packages is Zigistry, covered in
section 1.3.

### 1.5 How each candidate was pinned

```
git ls-remote --tags --heads https://github.com/<owner>/<repo>.git
```

The pin rule was: take the highest semantic version tag that exists, else the
default branch. The clone was then made at that ref:

```
git clone --depth 1 --branch <tag-or-branch> https://github.com/<owner>/<repo>.git \
    /tmp/scratch/ZigEcosystem/clones/<owner>__<repo>
```

The resolved commit came from `git rev-parse HEAD` in the clone. The star count
and the last push date came from:

```
gh api repos/<owner>/<repo>    # .stargazers_count, .pushed_at, .license.spdx_id
```

### 1.6 How each table cell was measured

| Cell | Command | Run in |
|---|---|---|
| `minimum_zig_version` | `cat build.zig.zon` then a regex on the `.minimum_zig_version` line | the clone |
| version | same file, `.version` field | the clone |
| dependencies | same file, `.dependencies` block | the clone |
| line count | `find . -name '*.zig' -not -path './.git/*' -print0`, then the resulting file list piped to `cat`, then to `wc -l` | the clone |
| I/O model | `grep -rn --include=*.zig -E 'std\.Io' <clone>`, and again for `cImport` and `translate-c` | the clone |
| fetchability | `zig fetch --global-cache-dir <scratch>/zcache https://github.com/<owner>/<repo>/archive/<sha>.tar.gz` | scratch |

The line count covers the whole tree. It includes tests, generators and
vendored data files. It is a size measure, not a quality measure. `nektro/zig-unicode-ucd`
is 90274 lines because it ships the whole Unicode Character Database as Zig
source.

## 2. Candidate table

### 2.1 The ladder

The shared context defines four rungs. They are repeated here because every
row in section 3 cites one.

| Rung | Meaning |
|---|---|
| 1 | Zig standard library |
| 2 | Zig package pinned in `build.zig.zon` |
| 3 | Zig `translate-c` binding to a system C library |
| 4 | hand-written C shim |

Rung 4 requires a named reason: a macro, an opaque handle, a callback with a
non-representable type, or varargs. No rung-4 entry appears in section 3.

### 2.2 The table

Path prefix for every `zon` cell: `/tmp/scratch/ZigEcosystem/clones/`.
`zfetch` is the `zig fetch` result from section 4.2: `ok` or `FAIL`.

| Name | Repository | Tag | Commit | zon | `minimum_zig_version` | `.zig` lines | I/O model | External deps | Pushed | Stars | `zig fetch` | Covers |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| goose | `luxluth/goose` | `v3.3.0` | `8c6ee3a9` | read-only ref checkout | `0.16.0` | 6412 | `std.Io` as a parameter | none | 2026-10-03 | 46 | ok | D-Bus client, server, object server, introspection, proxy codegen |
| dbus.zig | `LilithSemi/dbus.zig` | none | `0125f50a` | `LilithSemi__dbus.zig/build.zig.zon` | `0.16.0` | 6677 | raw `std.posix.read`, `std.Thread` | none | 2026-07-11 | 6 | ok | D-Bus client, daemon, object server, event loop, match rules |
| dbus-zig | `marler8997/dbus-zig` | none | `5a87bbb1` | `marler8997__dbus-zig/build.zig.zon` | `0.14.0` | 6009 | `std.Io` plus an `iobackport` shim | `iobackport` | 2026-08-12 | 21 | ok | D-Bus client and server |
| dbuz | `0xCatPKG/dbuz` | none | `d6578ef4` | `0xCatPKG__dbuz/build.zig.zon` | `0.15.2` | 6179 | `std.Io` | `dishwasher` | 2026-05-02 | 5 | ok | D-Bus client only, mirror of a Codeberg host |
| zig-dbus | `akunaakwei/zig-dbus` | none | `a6351864` | `akunaakwei__zig-dbus/build.zig.zon` | `0.16.0` | 335 | none, it is a C source package | `dbus` 1.16.2, `autoconfigheader` | 2026-09-20 | 0 | ok | Builds libdbus from C with `zig build` |
| zix11 | `baverman/zix11` | `0.9.0` | `3f9771d7` | `baverman__zix11/build.zig.zon` | `0.16.0` | 12936 | `std.Io` | none | 2026-06-27 | 5 | ok | Pure-Zig X11 protocol client, requests, properties, atoms |
| x11.zig | `fumeo-dev/x11.zig` | none | `77b0cb3e` | `fumeo-dev__x11.zig/build.zig.zon` | `0.16.0` | 1424 | `std.Io` | none | 2026-09-11 | 2 | ok | X11 connection setup and handshake only |
| x11.zig | `LilithSemi/x11.zig` | none | `32b02502` | `LilithSemi__x11.zig/build.zig.zon` | `0.16.0` | 27028 | `std.Io` | `xml`, `xcbproto` | 2026-10-03 | 1 | ok | Pure-Zig X11 with a protocol generator from xcb-proto XML |
| x11protocol | `thuvasooriya/x11protocol` | none | `4c615163` | `thuvasooriya__x11protocol/build.zig.zon` | `0.15.2` | 13657 | no `std.Io` | none | 2025-11-05 | 1 | ok | Hand-written X11 protocol structures |
| xcb-zig | `HaraldWik/xcb-zig` | none | `85fada06` | `HaraldWik__xcb-zig/build.zig.zon` | `0.16.0` | 1284 | `std.Io` | none | 2026-07-30 | 0 | ok | XCB codegen tool, core plus bigreq, sync, xevie |
| xcb.zig | `Midstall/xcb.zig` | none | `e2cfe150` | `Midstall__xcb.zig/build.zig.zon` | absent | 4058 | no `std.Io` | `libxcb`, `xcbproto`, `libxau`, `xcb-util`, `xcb-util-image`, `clap` | 2024-03-13 | 4 | FAIL | `translate-c` of libxcb, GPL-3.0 |
| xzb | `BanchouBoo/xzb` | none | `cb0959e9` | no `build.zig.zon` | n/a | 4452 | no `std.Io` | n/a | 2024-07-01 | 0 | n/a | Hand-written XCB bindings |
| libxzb | `incertia/libxzb` | none | `db24c1c0` | `incertia__libxzb/build.zig.zon` | `0.15.2` | 95 | no `std.Io` | none | 2025-10-29 | 0 | ok | XCB-like bindings, 95 lines only |
| zig-wayland | `ifreund/zig-wayland` | `v0.6.0` | `3c6da949` | `ifreund__zig-wayland/build.zig.zon` | `0.16.0` | 11328 | `std.Io`, thin | none | 2026-07-14 | 128 | ok | Zig protocol scanner and `libwayland-client` bindings |
| wayland | `allyourcodebase/wayland` | `1.24.0-4` | `1a08737f` | `allyourcodebase__wayland/build.zig.zon` | `0.16.0` | 634 | none, C package | `wayland`, `libffi`, `libexpat`, `libxml2`, `epoll-shim` | 2026-10-04 | 14 | ok | libwayland built with `zig build`, and `wayland-scanner` |
| wayland.zig | `tiawl/wayland.zig` | none | not cloned | from Zigistry | `0.17.0` | n/a | n/a | n/a | 2026-10-03 | 5 | not tried | Freedesktop headers packaged for Zig |
| zig-wayland-wire | `leroycep/zig-wayland-wire` | none | `b03a88f0` | `leroycep__zig-wayland-wire/build.zig.zon` | `0.11.0` | 3489 | no `std.Io` | `libxkbcommon` | 2024-02-21 | 3 | FAIL | Wire-level Wayland client, xdg-shell by hand |
| zig-wayland-client | `voidstar240/zig-wayland-client` | none | `d8c9df1` | `voidstar240__zig-wayland-client/build.zig.zon` | absent | 7268 | no `std.Io` | none | 2024-10-13 | 1 | FAIL | Pure-Zig Wayland client plus a scanner |
| wl-protocol-codegen | `ptrtoliam/wl-protocol-codegen` | none | `aec9ff7d` | `ptrtoliam__wl-protocol-codegen/build.zig.zon` | `0.16.0-dev.2261+d6b3dd25a` | 2591 | `std.Io`, thin | none | 2026-09-15 | 0 | ok | Codegen tool for Wayland protocol XML |
| zgl | `ziglibs/zgl` | none | `a73479a8` | `ziglibs__zgl/build.zig.zon` | absent | 12919 | no `std.Io` | none | 2026-05-26 | 630 | ok | OpenGL entry points and types, no function loader |
| zopengl | `zig-gamedev/zopengl` | none | `eda87248` | `zig-gamedev__zopengl/build.zig.zon` | `0.16.0` | 21701 | no `std.Io` | none | 2026-07-19 | 28 | ok | OpenGL bindings with a function loader and extension table |
| zigglgen | `castholm/zigglgen` | none | `38bfc858` | `castholm__zigglgen/build.zig.zon` | `0.16.0` | 72470 | `std.Io`, thin | none | 2026-09-29 | 160 | ok | OpenGL binding generator, emits zopengl |
| egl-headers | `AshishBhattarai/egl-headers` | none | not cloned | from GitHub search | n/a | n/a | n/a | n/a | 2025-09-25 | 1 | not tried | EGL headers packaged for Zig, nothing else |
| libxev | `mitchellh/libxev` | none | `9ce8e8e6` | `mitchellh__libxev/build.zig.zon` | `0.16.0` | 23508 | `std.Io` | none | 2026-07-17 | 3588 | ok | Event loop over io_uring, epoll, kqueue, IOCP |
| rotor | `c4milo/rotor` | `v0.6.0` | `59599a8` | `c4milo__rotor/build.zig.zon` | `0.16.0` | 49688 | `std.Io` | `pepegrillo`, `libuv`, `libxev`, all `lazy = true` | 2026-10-01 | 1 | ok | Event loop and I/O layer, io_uring with an epoll fallback |
| zio | `lalinsky/zio` | none | pinned `2662fdc4` | `~/zio/build.zig.zon` | `0.16.0` | not measured here | project runtime | none | 2026-10-04 | 630 | already in the project | Async runtime with epoll and kqueue backends |
| zig-xkbcommon | `ifreund/zig-xkbcommon` | `v0.4.0` | `2f3ecd85` | `ifreund__zig-xkbcommon/build.zig.zon` | `0.14.0` | 3133 | no `std.Io` | none | 2026-03-15 | 17 | ok | Hand-written `extern fn` bindings to libxkbcommon |
| xkbcommon.zig | `LilithSemi/xkbcommon.zig` | none | `d11d8dd0` | `LilithSemi__xkbcommon.zig/build.zig.zon` | `0.16.0` | 13915 | `std.Io` | `xml`, `xorgproto`, `x11` | 2026-10-03 | 1 | ok | Pure-Zig xkbcommon, parses the X11 wire replies |
| libxkbcommon | `allyourcodebase/libxkbcommon` | `1.13.2` | `466931e7` | `allyourcodebase__libxkbcommon/build.zig.zon` | `0.16.0` | 321 | none, C package | `libxkbcommon`, `libxml2` lazy | 2026-10-01 | 0 | ok | libxkbcommon built with `zig build` |
| zunic | `vrypan/zunic` | `v0.5.0` | `2ec52c05` | `vrypan__zunic/build.zig.zon` | `0.16.0` | 43276 | `std.Io` | none | 2026-09-19 | 2 | ok | Unicode 17 property tables, normalization, case folding, width |
| unicoder | `mnemnion/unicoder` | `v0.2.0` | `31f72232` | `mnemnion__unicoder/build.zig.zon` | `0.16.0` | 4080 | no `std.Io` | none | 2026-07-31 | 3 | ok | Codepoint and UTF-8/16 codecs, no property tables |
| zig-unicode-ucd | `nektro/zig-unicode-ucd` | none | `59f69a16` | no `build.zig.zon`, has `zig.mod` | n/a | 90274 | no `std.Io` | n/a | 2026-08-27 | 16 | n/a | Unicode Character Database as Zig source |
| poltergeist | `georgemandis/poltergeist` | `v0.2.0` | `ba6d96b2` | no `build.zig.zon` | n/a | 5459 | `std.Io` | n/a | 2026-06-13 | 2 | n/a | An accessibility CLI, binds libatspi over C |

Rows marked `not cloned` or `not tried` came from Zigistry or the GitHub
search only. Every other row was read from a clone.

### 2.3 Rows without a usable `build.zig.zon`

Four candidates cannot be fetched as Zig packages.

| Candidate | What it has instead | Consequence |
|---|---|---|
| `nektro/zig-unicode-ucd` | a `zig.mod` file | It is a zigmod package. `zig fetch` cannot consume it without a conversion. |
| `georgemandis/poltergeist` | no package file at all | It is an application, not a library. |
| `BanchouBoo/xzb` | no package file at all | Not consumable. |
| `Midstall/xcb.zig` | `.name` holds a string, not an enum literal | `zig fetch` rejects it. See section 4.2. |

## 3. One decision per dependency

Each subsection names the best package found, the rung, and the reason the
choice cannot sit on a lower-numbered rung. The rung numbers are the ones in
section 2.1.

### 3.1 D-Bus client and server

**Decision: keep `luxluth/goose` v3.3.0. Rung 2.**

The search did not find a better option at Zig 0.16.0. Four D-Bus packages
were cloned and read. None of them is better than goose for this port.

| Package | Why it does not replace goose |
|---|---|
| `LilithSemi/dbus.zig` 0.1.0 | Broader than goose: it also ships a bus daemon, an object server, an event loop and a match-rule parser. But it has no `std.Io` at all. `src/dbus/auth.zig:203` and `src/dbus/interfaces.zig:34` call `posix.read` directly, and `src/dbus/daemon/bus.zig:569` calls `std.Thread.spawn`. Under house rule 2 that is a violation, so it is rung 2 but unusable as-is. |
| `marler8997/dbus-zig` | `minimum_zig_version` is `0.14.0`, and it depends on `iobackport`, a backport of the old `std.io` API. The port targets 0.16.0, where `std.Io` exists, so the shim is dead weight. |
| `0xCatPKG/dbuz` | `minimum_zig_version` is `0.15.2`, client only, and a mirror of a Codeberg host. No server. |
| `akunaakwei/zig-dbus` | It is a libdbus C source package, not a Zig implementation. 335 lines of Zig total. |

**Does goose cover everything the AT-SPI path needs? No.** Three gaps are
real and were read in the goose source.

| Gap | goose evidence | What AccessKit needs | Consequence |
|---|---|---|---|
| Cannot connect to an address learned at run time | `src/connection.zig:1451` declares `const SocketIterator = struct {`, which is private and is not re-exported in `src/root.zig`. `initWithBackend` at `src/connection.zig:474` takes a `BusType`, not an address string. `.Accessibility` at `src/connection.zig:493-501` reads `$AT_SPI_BUS_ADDRESS` or falls back to `/run/user/<uid>/at-spi/bus_0`. | `/tmp/scratch/accesskit/adapters/unix/src/atspi/bus.rs:43-51` reads `$AT_SPI_BUS_ADDRESS` and, when it is empty, calls `BusProxy::new(session_bus).await?.get_address().await?` then `Builder::address(address)?`. The address arrives from the bus at run time. | The port cannot do the fallback with goose as published. Options: require `$AT_SPI_BUS_ADDRESS`, or carry a small local change to goose. The design document must pick one. |
| No unregister for an exported object | `registerObject` at `src/connection.zig:700` only appends to `registered_interfaces` (`src/connection.zig:285`). There is no public remove. | `bus.rs:194-254` calls `conn.object_server().remove::<T, _>(path)` when a node goes away, and `bus.rs:245-254` wraps it in `map_or_ignoring_recoverable_error`. | Object paths leak for the life of the process unless goose is extended. AT-SPI clients call `Get` on many paths, so a leak is a slow one, not a fatal one, but it is a leak. |
| No first-class emit-signal call | `registerSignalHandler` at `src/connection.zig:1163` is receive-side only. The public send path is `sendMessage` at `src/connection.zig:669` with `core.Message` and `core.MessageHeader`, both public in `src/core.zig`. | `bus.rs:256-395` emits `org.a11y.atspi.Event.Object` signals with a hand-built body. | The port writes a small signal-emit helper over `sendMessage`. This is about 40 lines. It is not a fork. |

Two further points are softer and do not block the decision.

| Point | Evidence |
|---|---|
| Threading model | `Backend` is `threaded` or `poll` (`src/connection.zig:122-125`). `serve` returns `error.InvalidBackend` for `.poll` at `src/connection.zig:892-894`. The threaded path spawns two threads at `src/connection.zig:870-879`. With zio already running the loop, the port uses `.poll` plus `getFd` (`src/connection.zig:292`), `hasDataToRead` (`src/connection.zig:297`) and `dispatch` (`src/connection.zig:312`). |
| Address forms | `grep -rn "abstract" /tmp/scratch/goose/src` returns no match, so `unix:abstract=` addresses are not handled. Whether the AT-SPI bus uses one on a given desktop is `UNVERIFIED` here. |

What goose does cover, and what the port needs: `AUTH EXTERNAL`
(`src/connection.zig:419-443`), `Hello` (`src/connection.zig:539`),
`RequestName` (`src/connection.zig:620`), `AddMatch`
(`src/connection.zig:1064`), the `org.freedesktop.DBus.Properties` trio with
generated introspection (`src/dispatcher.zig:72-253`), `Introspect` over
multiple registered interfaces (`src/connection.zig:930-970`), and object path
and variant types (`src/value.zig:737`, `src/core.zig:98`).

**Why it cannot sit higher than rung 2.** There is no D-Bus in the Zig
standard library. `lib/std` has no bus client. `[INFERENCE]`, from reading the
`lib/std` listing.

### 3.2 X11

**Decision: `baverman/zix11` 0.9.0, or a `translate-c` binding to `Xlib`. Rung 3
is the safe rung. Rung 2 is available and cheaper.**

| Candidate | Pin | What it really is |
|---|---|---|
| `baverman/zix11` | `3f9771d7`, tag `0.9.0`, `minimum_zig_version = 0.16.0`, no dependencies | Pure Zig X11. `src/connection.zig:123` `connect`, `src/connection.zig:288` `send(writer, request, flush)`, `src/root.zig:39` `getProperty`, `src/root.zig:125` `internAtom`. 12936 lines, 435 `std.Io` uses. |
| `LilithSemi/x11.zig` | `32b02502`, `minimum_zig_version = 0.16.0`, depends on `xml` and `xcbproto` | Pure Zig X11 with a protocol generator that reads `xcb-proto` XML. 27028 lines. `build.zig:1-22` exports `generateProtocol`, which downstream build files call. |
| `fumeo-dev/x11.zig` | `77b0cb3e`, `minimum_zig_version = 0.16.0`, no dependencies | Only the connection setup. `src/Client.zig:17` `open(allocator, io, display)`, `src/Handshake.zig:231` `perform`. 1424 lines. No request encoding. |
| `thuvasooriya/x11protocol` | `4c615163`, `minimum_zig_version = 0.15.2` | Structures only. Zero `std.Io` uses. |

**Recommended rung: 2, with `baverman/zix11`.** It takes an allocator and an
`io`, so it satisfies house rule 2 and house rule 5 without adaptation.

**Why it cannot sit on rung 1.** The Zig standard library has no X11 client.

**Why the rung-2 option is still open.** `[INFERENCE]` zix11 is 5 stars with
one author. The design document should keep `translate-c` of `X11/Xlib.h` as
the fallback because `Xlib` is present on this host: `/usr/include/X11` exists
and `/usr/lib64/libX11.so` is a symlink to `libX11.so.6.4.0`
`[OBSERVED: ls /usr/lib64]`.

### 3.3 XCB

**Decision: no pure-Zig XCB. Rung 3.**

| Candidate | Pin | Why it does not work |
|---|---|---|
| `HaraldWik/xcb-zig` | `85fada06`, `minimum_zig_version = 0.16.0`, no dependencies | Fetches. But `build.zig:42-74` lists the generated protocols and every extension except four is commented out. Live: `core`, `bigreq`, `sync`, `xevie`. Commented out: `xfixes`, `xkb`, `shm`, `composite`, `render`, `randr`, `xinput`, `xtest`. |
| `Midstall/xcb.zig` | `e2cfe150` | The `.name` field holds a string, so `zig fetch` fails. The dependency list is six C tarballs. Licence is GPL-3.0. |
| `incertia/libxzb` | `db24c1c0`, 95 lines | A stub. |
| `BanchouBoo/xzb` | `cb0959e9` | No `build.zig.zon`. 0 stars, last push 2024-07-01. |

The port needs XFIXES and XKB on the X11 path. `HaraldWik/xcb-zig` generates
neither today.

**Rung 3 is the answer.** `xcb` is present on this host: `/usr/include/xcb`
exists, `/usr/lib64/libxcb.so` is a symlink to `libxcb.so.1.1.0`, and there is a
`/usr/lib64/pkgconfig/xcb.pc`
`[OBSERVED: pkg-config --list-all | grep xcb]`.

**Why it cannot sit higher.** No Zig package generates the XCB extensions the
port needs. Uncommenting the list in `xcb-zig` is possible in principle, but
that is a fork of a 0-star repository, which is worse than rung 3.

### 3.4 Wayland client protocol, and xdg-shell

**Decision: `ifreund/zig-wayland` v0.6.0 for the generated Zig, plus
`libwayland-client` from `allyourcodebase/wayland` or the system. Rung 3.**

**There is no pure-Zig Wayland client.** Three packages were read.

| Candidate | Pin | What it really is |
|---|---|---|
| `ifreund/zig-wayland` | `3c6da949`, tag `v0.6.0`, `minimum_zig_version = 0.16.0`, no dependencies, 128 stars | A Zig **generator** plus `extern fn` declarations for libwayland. `src/ffi.zig:8-37` declares `wl_display_connect`, `wl_display_dispatch`, `wl_proxy_marshal_array_constructor_versioned` and the rest. The example build file ends with a `linkSystemLibrary` call for `wayland-client`. |
| `allyourcodebase/wayland` | `1a08737f`, tag `1.24.0-4`, `minimum_zig_version = 0.16.0`, 14 stars | libwayland built with `zig build`. Its `README.md:20-27` exposes `wayland-client`, `wayland-server`, `wayland-egl`, `wayland-cursor` and `wayland-scanner` as build artifacts. It carries **no** Zig protocol bindings. |
| `voidstar240/zig-wayland-client` | `d8c9df1` | Looks pure Zig, but `zig fetch` fails: the `.name` field holds a string. Last push 2024-10-13. |
| `leroycep/zig-wayland-wire` | `b03a88f0`, `minimum_zig_version = 0.11.0` | Wire-level client with `xdg_wm_base` written by hand in `examples/00_client_connect.zig`. `zig fetch` fails on the string name. Last push 2024-02-21. |

**xdg-shell specifically.** `ifreund/zig-wayland` does generate it. The
`README.md` shows `scanner.addSystemProtocol` with the path
`stable/xdg-shell/xdg-shell.xml`, then `scanner.generate("xdg_wm_base", 3)`, and the shipped example at
`example/hello/build.zig:14-21` does exactly that. `example/hello/hello.zig:72-82`
uses `xdg_surface.getToplevel()`, `xdg_toplevel.setListener` and
`xdg_toplevel.destroy`.

**The blocker for xdg-shell on this host.** `build.zig:106` and
`build.zig:112-119` of `ifreund/zig-wayland` find protocol XML with
`pkg-config --variable=pkgdatadir wayland-protocols`. That package is not
installed here:

```
$ pkg-config --variable=pkgdatadir wayland-protocols
(returns nothing, exit code 1)
$ ls /usr/share/wayland-protocols
No such file or directory
$ ls /usr/share/wayland
wayland-scanner.mk  wayland.dtd  wayland.xml
```

The core `wayland.xml` is present. `xdg-shell.xml` is not. The build can point
the scanner at a vendored copy instead, which is what `build.zig:15-17` does
for its own test: it passes an unchanging vendored `wayland.xml`.

**Why it cannot sit higher.** A pure-Zig Wayland client would be rung 2. None
exists that both fetches and covers xdg-shell. `voidstar240/zig-wayland-client`
is the closest, and it does not fetch on Zig 0.16.0.

**One more option, noted and not recommended.** `ptrtoliam/wl-protocol-codegen`
(`aec9ff7d`) is a second protocol generator with a `protocols` option, and it
fetches. Its `minimum_zig_version` is `0.16.0-dev.2261+d6b3dd25a`, a
development build. `[INFERENCE]` a 0.16.0 release build can fetch it, but the
pin would drift.

### 3.5 EGL and OpenGL, and the extension loading problem

**Decision: `zig-gamedev/zopengl` for OpenGL, `translate-c` of
`EGL/egl.h` for EGL. Rung 3 for EGL, rung 2 for OpenGL.**

**EGL: nothing exists.** The searches were `egl language:zig` (3 results),
`egl.zig` (3 results) and `egl opengl bindings zig` (0 results)
`[OBSERVED: gh api search/repositories]`. The only package is
`AshishBhattarai/egl-headers`, 1 star, last push 2025-09-25, described as
"egl headers packaged for zig". That is a header copy, not a binding, and it
was **not cloned**.

**EGL headers are not on this host.** `/usr/include/EGL` does not exist
`[OBSERVED: os.path.isdir]`. `/usr/lib64` has `libEGL.so.1` and
`libEGL_mesa.so.0`, but no `libEGL.so` development symlink
`[OBSERVED: ls /usr/lib64]`. `pkg-config --modversion egl` fails.

**OpenGL: two packages, and the difference matters.**

| Package | Pin | Loader |
|---|---|---|
| `zig-gamedev/zopengl` | `eda87248`, `minimum_zig_version = 0.16.0`, 21701 lines, 28 stars | Yes. `src/zopengl.zig:17` `pub const LoaderFn = *const fn ([*:0]const u8) callconv(.c) ?*const anyopaque`, `:39` `loadCoreProfile`, `:845` `loadEsProfile`, `:1073` `loadExtension`, `:784` `loadCompatProfileExt`. |
| `ziglibs/zgl` | `a73479a8`, **no `minimum_zig_version` field**, 12919 lines, 630 stars | No. A grep for `getProcAddress` over the clone returns nothing. `src/zgl.zig:1-4` imports `binding.zig` as the binding module, so every entry point is an `extern fn` resolved at link time. |

**The extension loading problem.** `LoaderFn` takes a name and returns a
function pointer. Nothing supplies that function. The two suppliers in the
wild are `eglGetProcAddress` and `glXGetProcAddressARB`, both C library
entry points. That is why OpenGL is rung 2 but the loader itself drags the
answer down to rung 3 for EGL and GLX.

**Why OpenGL can sit on rung 2.** `zopengl` fetches, declares
`minimum_zig_version = 0.16.0`, and has no dependencies.

**Why EGL cannot.** No Zig package, and no headers on this host.

`castholm/zigglgen` (`38bfc858`, 72470 lines) is a generator, not a binding.
It is listed in the table for completeness.

### 3.6 Main loop and event source

**Decision: `zio` 0.18.0. Rung 2. Already in the project, not re-decided here.**

The alternative packages are listed so the design document knows what it is
rejecting.

| Package | Pin | Model |
|---|---|---|
| `zio` | `~/zio`, `minimum_zig_version = 0.16.0`, `.dependencies = .{}` | `src/ev/backends/linux/epoll.zig:536` `registerSocket`, `src/ev/backends/linux/kqueue`-equivalent paths, `src/common.zig:608` `waitForIo`, `src/blocking_task.zig:189` `spawnBlockingTask`. |
| `mitchellh/libxev` | `9ce8e8e6`, `minimum_zig_version = 0.16.0`, 23508 lines, 3588 stars | `src/backend.zig:5-8` `Backend = enum { io_uring, epoll, kqueue, … }`, `:55` `.iocp`. Owns the loop. |
| `c4milo/rotor` | `59599a8`, tag `v0.6.0`, `minimum_zig_version = 0.16.0`, 49688 lines, 1 star | io_uring with an epoll fallback. Its three dependencies are `lazy = true` and, per the comments in its `build.zig.zon`, bench-only. |

**Why `zio` sits above the others.** It is already a project dependency and
`spawnBlockingTask` is exactly what the AT-SPI adapter needs for the blocking
`XGetInputFocus` and `GetKeyboardMapping` calls. `libxev` and `rotor` would
mean two loops in one process.

**Why it cannot sit on rung 1.** The Zig standard library has no event loop in
0.16.0. `[INFERENCE]`.

### 3.7 Reading and parsing the XKB keymap

**Decision: `LilithSemi/xkbcommon.zig`. Rung 2. UNVERIFIED at run time.**

`LilithSemi/xkbcommon.zig` at `d11d8dd0` parses the X11 wire replies directly
and needs no C library at all. `build.zig:22-24` says so in a comment: "Pure-Zig
XML parser (ianprime0509/zig-xml) for the registry. Zero C deps."

The functions the port needs are present.

| Function | Path | Note |
|---|---|---|
| `parseGetMap` | `src/x11.zig:226` | turns `XkbGetMap` bytes into a `MapView` |
| `parseGetNames` | `src/x11.zig:318` | `NamesView` |
| `parseGetControls` | `src/x11.zig:334` | `ControlsView` |
| `parseGetCompatMap` | `src/x11.zig:349` | `CompatView` |
| `setupXkb` | `src/x11.zig:366` | negotiates the XKB extension |
| `keymapNewFromDevice` | `src/x11.zig:504` | full path from a device id |
| `keymapFromGetMap` | `src/x11.zig:667` | full path from captured bytes |

It depends on `LilithSemi/x11.zig` at commit `32b02502`, the same commit as
`LilithSemi__x11.zig/build.zig.zon` records. Both declare
`minimum_zig_version = 0.16.0` and both fetched.

**The rejected alternatives.**

| Package | Pin | Reason rejected |
|---|---|---|
| `ifreund/zig-xkbcommon` | `2f3ecd85`, tag `v0.4.0`, `minimum_zig_version = 0.14.0` | 79 hand-written `extern fn` declarations for libxkbcommon. `build.zig:3-7` only calls `addModule`; the consumer must link `xkbcommon` itself. This host has no libxkbcommon. |
| `allyourcodebase/libxkbcommon` | `466931e7`, tag `1.13.2`, `minimum_zig_version = 0.16.0` | A C source package, 321 lines of Zig. Builds libxkbcommon. Rung 3 in effect. |

**Why it cannot sit on rung 1.** `lib/std/unicode.zig` decodes UTF-8, UTF-16
and UTF-32. It has no XKB grammar. `[OBSERVED: the only pub decls in
lib/std/unicode.zig are replacement_character, Utf8, Utf16, Utf32, Wtf8]`.

**House rules.** `xkbcommon.zig` has 57 `std.Io` uses and takes a client
object, so `io` is a parameter. `parseGetMap`, `parseGetNames`,
`parseGetControls` and `parseGetCompatMap` are pure functions over bytes with
an allocator argument. That matches house rule 3, "network logic is pure over
bytes".

### 3.8 UTF-8 and a Unicode property table

**Decision: nothing. Rung 1. No package needed.**

**AccessKit does not use a Unicode property table.** The check was a grep over
the whole upstream tree for the usual calls:

```
grep -rn -E 'to_lowercase|to_uppercase|is_alphabetic|is_alphanumeric|is_whitespace|unicode_normalization|from_u32|is_control|nfkd|NFKC|grapheme' --include=*.rs /tmp/scratch/accesskit
```

The result was empty `[OBSERVED: same command, zero lines]`. The only Unicode
operation in the whole tree is `char::len_utf16`, at
`accesskit_consumer/src/text.rs:273`, `:276`, `:1614` and `:1625`.

`lib/std/unicode.zig` covers UTF-8, UTF-16, UTF-32 and WTF-8, which is enough.

**The packages found anyway, for the record.**

| Package | Pin | What it would give | Why it is not used |
|---|---|---|---|
| `vrypan/zunic` | `2ec52c05`, tag `v0.5.0`, `minimum_zig_version = 0.16.0`, 43276 lines | Unicode 17 property tables. `src/cp/cp.zig:21` `general`, `:26` `script`, `:38` `bidi`, `:74` `width`, `:109` `fullCaseFold`, `:135` `canonicalCombiningClass`, `:152` `numeric`. Vendored data in `src/data/*-17.0.0.txt`. | No consumer. Its `README.md` also warns that it is AI-generated throughout. |
| `nektro/zig-unicode-ucd` | `59f69a16` | The whole UCD as Zig source, Unicode 17.0.0. | It is a zigmod package with no `build.zig.zon`, so `zig fetch` cannot consume it. |
| `mnemnion/unicoder` | `31f72232`, tag `v0.2.0`, `minimum_zig_version = 0.16.0`, 4080 lines | Codepoint and encoding codecs. | No property tables. It reimplements `std.unicode`. |

**If a property table ever becomes needed**, `vrypan/zunic` is the only
candidate that fetches on Zig 0.16.0 and carries the tables. That is rung 2 and
the pin is `2ec52c05`.

### 3.9 AT-SPI data types, separate from D-Bus transport

**Decision: none found. Write them from the D-Bus XML. Rung 1.**

**Searches.** `atspi language:zig` returned `total_count = 0`.
Zigistry `?q=atspi` returned `total = 0`. Zigistry `?q=accessibility` returned
`total = 72`, and every hit was unrelated: `dvui`, `sokol-zig`, `libqt6zig`,
`nanovg-zig`, `zuckdb.zig`. None defines AT-SPI types.
`[OBSERVED: both queries, see section 1.2 and 1.3]`.

**The one package that touches AT-SPI uses the C library.**
`georgemandis/poltergeist` at `ba6d96b2` is an accessibility command line tool.
Its `src/platform/linux_atspi.zig:63-77` is a list of `extern` declarations for
the `atspi` library: `atspi_init`, `atspi_get_desktop`,
`atspi_accessible_get_name`, `atspi_accessible_get_role` and so on. It is a
consumer of libatspi over C, not a source of AT-SPI types, and it is an
application with no `build.zig.zon`.

**What the port must write.** The AT-SPI types are the value types in
`adapters/unix/src/atspi/interfaces/`: `Accessible`, `Action`, `Component`,
`Document`, `EditableText`, `Hyperlink`, `Image`, `Selection`, `Text`, `Value`,
plus `Cache`, `Application`, `RootAccessible` and the `Event.Object` signals.
`docs/13-atspi-protocol.md` enumerates them. They are plain Zig structs with
D-Bus signatures, which is rung 1 work.

**Why it cannot sit higher.** There is no package to sit on.

### 3.10 Rung summary

| Dependency | Rung | Chosen artefact | Second choice |
|---|---|---|---|
| D-Bus | 2 | `goose` `8c6ee3a9` | none; three gaps listed in 3.1 |
| X11 | not taken, rung 2 | `zix11` `3f9771d7` | rung 3, `X11/Xlib.h` |
| XCB | not taken, rung 3 | `translate-c`, `xcb/xcb.h` | none |
| Wayland and xdg-shell | not taken, rung 3 | `zig-wayland` `3c6da949` plus libwayland | vendor `xdg-shell.xml`, still rung 3 for libwayland |
| OpenGL | 2 | `zopengl` `eda87248` | `zgl` `a73479a8`, but it has no loader |
| EGL and GLX | 3 | `translate-c`, `EGL/egl.h` | none |
| Main loop | 2 | `zio` | `libxev` `9ce8e8e6`, `rotor` `59599a8` |
| XKB | 2 | `xkbcommon.zig` `d11d8dd0` | rung 3, `allyourcodebase/libxkbcommon` `466931e7` |
| Unicode | 1 | `std.unicode` | `zunic` `2ec52c05`, unused |
| AT-SPI types | 1 | write them | none |

**The X11, XCB and Wayland rows are not taken.** Upstream ships no adapter for
either surface, so there is nothing to port. The table surveys what the ecosystem
offers rather than what the port selects, which is why the packages stay listed.
`docs/22-zig-build-surface.md:2186-2191` closes the rung, and `:508` marks
`linkSystemLibrary("xcb", …)` **Not used**.

**No rung-4 entry appears.** No dependency needed a hand-written C shim.

## 4. Availability on this machine

### 4.1 What "verified" means here

Three levels are used and are named in every row.

| Level | Meaning |
|---|---|
| fetched | `zig fetch` returned exit code 0 and printed a package hash. |
| header/library present | the header directory or the `.so` development symlink exists on disk. |
| unverified | neither of the above was established. |

No `zig build` was run. The instructions for this wave forbid it. So
"compiles under Zig 0.16.0" is **not** established for any package below.

### 4.2 `zig fetch` results

Command shape, one per candidate:

```
zig fetch --global-cache-dir /tmp/scratch/ZigEcosystem/zcache \
  https://github.com/<owner>/<repo>/archive/<full-sha>.tar.gz
```

```
$ zig fetch --global-cache-dir /tmp/scratch/ZigEcosystem/zcache \
    https://github.com/luxluth/goose/archive/8c6ee3a984a3b314bb921e3f8f6428a51a6d93e1.tar.gz
goose-3.3.0-e9MzMIEpBACANYPKd-lGDjoxFHcbYTKmfMWA4c0XK_wZ
```

Of the 30 candidates listed below, 27 carry a `build.zig.zon`. Those 27 were
fetched. 24 succeeded and 3 failed. Full log:
`/tmp/scratch/ZigEcosystem/zig-fetch.log`.

| Package | Result |
|---|---|
| `luxluth/goose` | ok, `goose-3.3.0-e9MzMIEpBACANYPKd-lGDjoxFHcbYTKmfMWA4c0XK_wZ` |
| `LilithSemi/dbus.zig` | ok, `dbus-0.1.0-8F4MwE4aBACvANrm5A5bt6pw_FMWVk_Bs_ymMatzbR-x` |
| `baverman/zix11` | ok, `zix11-0.9.0-6Ond5_aOBQCzTebhC99-96NhpSHnw9txI5IKL6C-1umD` |
| `LilithSemi/x11.zig` | ok, `x11-0.1.0-dfzXO3ABEgDh_aano5-90TqY5zHjGEPc1lw4dAy7l-Pg` |
| `fumeo-dev/x11.zig` | ok, `x11-0.0.0-VQdUpEmGAACv8UAURM3KF45Kqn0-W4mqsMQf6H1ynDie` |
| `LilithSemi/xkbcommon.zig` | ok, `xkbcommon-0.1.0-6Tc_PVVqCACIec--fvhX1jyDbG7fko597bOOBodHiOvy` |
| `thuvasooriya/x11protocol` | ok, `x11protocol-0.0.0-rJ0IzPXFAwDuP-YtRBECq4rTxOvaz0O16d2y_wpaBq` |
| `HaraldWik/xcb-zig` | ok, `xcb-0.0.0-OuD1_3aACgCyUZe4fNIpe-A5a4pZrJOKCw_bhJW5JKay` |
| `ifreund/zig-wayland` | ok, `wayland-0.6.0-lQa1kqz8AQADQmdNJsNhLoNHcnEGEUjrOaPV-dtEnEmX` |
| `allyourcodebase/wayland` | ok, `wayland-1.24.0-4-dxEBa-N8AABxP_wW0QMcnzmY_h_P1sqtpY9tenhmLz1` |
| `ptrtoliam/wl-protocol-codegen` | ok, `wl_protocol_codegen-0.1.0-vEA_tzIoAQBfYQiZ8rA6Hj0wh1GTZW7iJ-` |
| `zig-gamedev/zopengl` | ok, `zopengl-0.6.0-dev-5-tnz8mnDgCHR72YtUpLBYW_u4JgZ0Ub-UFX-M0zRS` |
| `ziglibs/zgl` | ok, `zgl-1.1.0-p_NpAD9FCgAY_XDO_EXxSGJ5-n9b3deO0V-9z9HJKYTQ` |
| `castholm/zigglgen` | ok, `zigglgen-0.5.1-ziggliTOLwAZfmk4DG9VLmHGE2BexC4o_O5yZKW37vfl` |
| `ifreund/zig-xkbcommon` | ok, `xkbcommon-0.4.0-VDqIe0i2AgDRsok2GpMFYJ8SVhQS10_PI2M_CnHXsJJZ` |
| `allyourcodebase/libxkbcommon` | ok, `libxkbcommon-1.13.2-93LaF2h7AgBIG6oyBvFuUyyiC8Puj0v5OGLE4a5r` |
| `vrypan/zunic` | ok, `zunic-0.5.0-yeyUTQnOAAFkzjXRgvW4KsrZIlaSIta1AfGfLL9hW7ud` |
| `mnemnion/unicoder` | ok, `unicoder-0.2.0-f6uOBUVtAgBvyehq1ESMc6OANLcLDmzejkJ1rMAQ9Azt` |
| `mitchellh/libxev` | ok, `libxev-0.0.0-86vtcwIRFADbH4hk-EjROXxlrKIRPQdA41XiTSytYO-F` |
| `c4milo/rotor` | ok, `rotor-0.6.0-YZkxRImMEwBfvylbAcRm5qlHtIiE1PRaXI9A76wXG4NO` |
| `marler8997/dbus-zig` | ok, `dbus-0.0.0-hqwuPlGzAgD60X1QKbPg6PlSL3lPkoKXnoo4-i9cazp8` |
| `0xCatPKG/dbuz` | ok, `dbuz-0.0.2-hjtW5U6DAwDSg9dhwdTV9k6TNVCDb5SQ1NIhNz0oK6Pb` |
| `akunaakwei/zig-dbus` | ok, `dbus-1.16.2-CcRkApk_AABOo67ljJ4V2GefbK5BlGhnbqQlOuNwXSp5` |
| `incertia/libxzb` | ok, `libxzb-0.0.0-HOZbpFojAAA4DgOpsRCr2xMPNUZcuit4MIQEUxqqoxJs` |
| `Midstall/xcb.zig` | **FAIL** |
| `voidstar240/zig-wayland-client` | **FAIL** |
| `leroycep/zig-wayland-wire` | **FAIL** |
| `nektro/zig-unicode-ucd` | not attempted, no `build.zig.zon` |
| `georgemandis/poltergeist` | not attempted, no `build.zig.zon` |
| `BanchouBoo/xzb` | not attempted, no `build.zig.zon` |

All three failures are the same defect. The old string form of `.name` is
rejected by the Zig 0.16.0 package reader:

```
$ zig fetch .../Midstall/xcb.zig/archive/e2cfe150...tar.gz
build.zig.zon:2:13: error: expected enum literal
    .name = "xcb.zig",
            ^~~~~~~~~
exit code 1

$ zig fetch .../voidstar240/zig-wayland-client/archive/d8c9df1...tar.gz
build.zig.zon:2:13: error: expected enum literal
    .name = "wayland-client",
            ^~~~~~~~~~~~~~~~
exit code 1

$ zig fetch .../leroycep/zig-wayland-wire/archive/b03a88f0...tar.gz
build.zig.zon:2:13: error: expected enum literal
    .name = "zig-wayland-wire",
            ^~~~~~~~~~~~~~~~~~~~
exit code 1
```

`AshishBhattarai/egl-headers` and `tiawl/wayland.zig` were **not fetched**.
Both are marked UNVERIFIED.

### 4.3 System C libraries and headers on this host

Measured with `pkg-config --list-all`, `ls /usr/lib64`, `ls /usr/include` and
`os.path.isfile`. All results `[OBSERVED]`.

| Library | Headers | `.pc` file | Development symlink | Verdict |
|---|---|---|---|---|
| `X11` | `/usr/include/X11` yes | `x11.pc` | `libX11.so -> libX11.so.6.4.0` | usable for rung 3 |
| `Xext` | yes | none seen | `libXext.so` yes | usable |
| `xcb` | `/usr/include/xcb` yes | `xcb.pc` | `libxcb.so -> libxcb.so.1.1.0` | usable for rung 3 |
| `xcb-xfixes` | yes | `xcb-xfixes.pc` | yes | usable |
| `xcb-xkb` | yes | `xcb-xkb.pc` | yes | usable |
| `xcb-shm` | yes | `xcb-shm.pc` | yes | usable |
| `xcb-composite`, `xcb-damage`, `xcb-render`, `xcb-randr`, `xcb-shape`, `xcb-sync` | yes | `.pc` each | yes | usable |
| `X11-xcb` | yes | `x11-xcb.pc` | `libX11-xcb.so` yes | usable |
| `wayland-client` | `/usr/include/wayland-client.h` yes | `wayland-client.pc` | `libwayland-client.so -> libwayland-client.so.0` | usable for rung 3 |
| `wayland-scanner` | yes | `wayland-scanner.pc` | n/a | present |
| `wayland-egl` | yes | `wayland-egl.pc` | `libwayland-egl.so` yes | usable |
| `dbus-1` | yes | `dbus-1.pc` | `libdbus-1.so` yes | present, but rejected in favour of goose |
| `glib-2.0`, `gobject-2.0`, `gio-2.0` | yes | `.pc` each | yes | present, but not needed |
| `EGL` | **no**, `/usr/include/EGL` absent | **no**, `pkg-config --modversion egl` fails | **no**, only `libEGL.so.1` and `libEGL_mesa.so.0` | **not usable for rung 3 here** |
| `GL` | `/usr/include/GL` yes | **no**, `pkg-config --modversion gl` fails | **no**, only `libGL.so.1` | **not usable for rung 3 here** |
| `GLESv2` | yes | **no**, `pkg-config --modversion glesv2` fails | **no**, only `libGLESv2.so.2` | **not usable for rung 3 here** |
| `xkbcommon` | **no**, `/usr/include/xkbcommon` absent | **no** | **no**, no `libxkbcommon.so*` | **not usable** |
| `atspi-2` | **no**, `/usr/include/at-spi-2.0` absent | **no** | **no**, only `libatspi.so.0` | **not usable** |

`wayland-protocols` is **not** installed. `/usr/share/wayland` holds only
`wayland-scanner.mk`, `wayland.dtd` and `wayland.xml`.

The EGL and GL finding matters for section 6. The port needs EGL at run time,
so a rung-3 EGL binding cannot be built on this host without a package
install. `docs/05-platform-feasibility.md` covers what the runtime looks like.

### 4.4 `zig translate-c` was not verified

`zig translate-c` was attempted against `X11/Xlib.h`, `xcb/xcb.h`,
`EGL/egl.h`, `GL/gl.h`, `xkbcommon/xkbcommon.h`, `xcb/xkb.h`,
`xcb/xfixes.h`, `wayland-client.h` and `atspi/atspi.h`.

Result: **unverified**. The first attempts returned
`error: CacheCheckFailed` for every header. Two of the same invocations
succeeded earlier in the same session, so `CacheCheckFailed` is an environment
condition and not a property of the headers. `[OBSERVED: repeated
`/tmp/cache/zig/.../zig translate-c <header> -I/usr/include -lc`,
exit code 1 and 0 on different runs of the same command]`.

Two usage facts were learned and are recorded so the design document does not
repeat them. In Zig 0.16.0 `translate-c` writes to standard output, and it
does not accept `-o`. A first attempt that put the header last on the command
line made `zig` treat the header path as the output name.

The table in section 4.3 is therefore the evidence for rung 3, not a
`translate-c` run.

### 4.5 Unverified list

Everything below is **UNVERIFIED**.

| Item | Why |
|---|---|
| That any candidate compiles on Zig 0.16.0 | `zig fetch` reads `build.zig.zon` only. `zig build` was forbidden by the wave instructions. |
| `ziglibs/zgl` on Zig 0.16.0 | Its `build.zig.zon` has **no** `.minimum_zig_version` field, so `zig fetch` applies no gate. |
| `AshishBhattarai/egl-headers` | Not cloned, not fetched. |
| `tiawl/wayland.zig` | Not cloned, not fetched. Zigistry reports `minimum_zig_version = 0.17.0`, which is above the pinned compiler, so it is excluded anyway. |
| `LilithSemi/xkbcommon.zig` correctness against a live X server | It parses wire bytes. The bytes it was tested against are in its own `test/` and `data/` directories, which were not run. |
| That goose handles `unix:abstract=` addresses | No `abstract` match in goose sources. Whether the AT-SPI bus uses one is desktop dependent. |
| That the AT-SPI bus address on a real desktop is a filesystem path | Not observed in this document. No AT-SPI bus was contacted here. `docs/26-goose-live-bus-probe.md:18,26` answers it two days later: `busctl --user call org.a11y.Bus GetAddress` returns `unix:path=/run/user/33156/at-spi/bus` |

## 5. The Windows and macOS answer

Neither platform can be exercised on this host. What follows is what the Zig
distribution ships and what the ecosystem offers. Everything that needs the
target SDK is marked UNVERIFIED.

### 5.1 Windows UI Automation

**Zig 0.16.0 ships the headers. No SDK is needed for a `translate-c` binding.**

The Zig distribution bundles MinGW headers under
`lib/libc/include/any-windows-any/`. The files the UI Automation path needs are
all present `[OBSERVED: os.path.isfile on that directory]`.

| Header | Present | What it carries |
|---|---|---|
| `uiautomationclient.h` | yes | `IUIAutomation` and the pattern interfaces. Verified by grep: the string `IUIAutomation` occurs in it. |
| `uiautomationcore.h` | yes | `UIA_*` element identifiers |
| `uiautomationcoreapi.h` | yes | provider entry points |
| `objbase.h` | yes | COM: `IUnknown`, `CoInitializeEx`, `CoCreateInstance` |
| `combaseapi.h` | yes | `CoTaskMemAlloc`, `StringFromGUID2` |
| `oaidl.h`, `servprov.h` | yes | automation IDL and service provider interfaces |
| `ole2.h` | yes | `VARIANT`, `BSTR` |
| `winuser.h`, `wingdi.h`, `winerror.h` | yes | windows, device contexts, error codes |

The import libraries are bundled too:
`lib/libc/mingw/lib32/uiautomationcore.def` exists and starts with
`LIBRARY "UIAutomationCore.DLL"`. `lib/libc/mingw/lib-common/uiautomationcore.def`
also exists. `[OBSERVED: ls and head on those two paths]`.

**The Zig standard library has no UI Automation.** `grep -ril 'uiautomation'`
over `lib/std` returns nothing. `grep -ril 'IUIAutomation'` returns nothing.
`lib/std/os/windows.zig` exposes `kernel32`, `ntdll`, `ws2_32`, `crypt32` and
friends, but no UIA module. `[OBSERVED: ls lib/std/os/windows/ shows crypt32.zig,
kernel32.zig, lang.zig, nls.zig, ntdll.zig, ntstatus.zig, sublang.zig, tls.zig,
win32error.zig and ws2_32.zig]`.

**No Zig UI Automation package exists.** `ui automation windows language:zig`
returned `total_count = 0`. `windows uia zig` returned `total_count = 0`.
`[OBSERVED: both queries]`.

**Decision: rung 3, `translate-c` over the bundled MinGW headers.**

**Why it cannot sit higher.** No Zig package. No standard library module. The
API is COM, so a binding needs the interface vtables.

**How much can be checked without the target SDK.** Most of it.

| Check | Possible here | How |
|---|---|---|
| Header availability | yes | `os.path.isfile`, done |
| `translate-c` of `uiautomationclient.h` | **UNVERIFIED** | `zig translate-c` was unreliable here, section 4.4. The integration owner should retry it. |
| Cross-compile the binding | **UNVERIFIED** | `zig build` was forbidden. |
| Link against `uiautomationcore` | **UNVERIFIED** | needs the `.def`, which is present, and a link step |
| Runtime behaviour against a live UIA tree | no | needs Windows |

The bundled headers remove the SDK as a blocker for the binding itself. That
is the single most useful finding in this section.

### 5.2 macOS accessibility

**Upstream uses Objective-C, not a C API.**
`/tmp/scratch/accesskit/adapters/macos/Cargo.toml` lists
`objc2` at `0.5.1`, `objc2-foundation` with the `NSArray`, `NSDictionary`,
`NSValue` and `NSThread` features, and `objc2-app-kit` with the
`NSAccessibility`, `NSAccessibilityConstants`, `NSAccessibilityElement`,
`NSAccessibilityProtocols`, `NSColor`, `NSResponder`, `NSText`, `NSView` and
`NSWindow` features. No C accessibility library is listed.

**Zig options found.**

| Package | Pin | What it offers |
|---|---|---|
| `mitchellh/zig-objc` | not cloned | Objective-C runtime bindings for Zig, 355 stars, last push 2026-04-17 `[OBSERVED: gh api repos/mitchellh/zig-objc]`. UNVERIFIED in detail. |
| `colbyhall/objective-zig` | not cloned | Runtime and bindings to common Objective-C frameworks, 18 stars `[OBSERVED: same query]`. UNVERIFIED in detail. |
| `robbielyman/corefoundation.zig` | not cloned | 1 star, last push 2025-09-27. UNVERIFIED in detail. |
| `yoyo-67/zigmac` | not cloned | 0 stars, last push 2026-09-10. UNVERIFIED in detail. |

**Decision: rung 3.** Two routes exist and both need the SDK.

| Route | What it needs | Verdict |
|---|---|---|
| `translate-c` of the `ApplicationServices` C API, `AXUIElementCreateApplication` and friends | the macOS SDK | UNVERIFIED. Zig ships no macOS headers. |
| Objective-C runtime bindings, then message sends to `NSAccessibility` | the macOS SDK plus a runtime binding | UNVERIFIED, and heavier than the C route |

**Why it cannot sit higher.** `cocoa accessibility language:zig` returned
`total_count = 0`. No package implements the accessibility API.

**How much can be checked without the target SDK.** Only the search.

| Check | Possible here | How |
|---|---|---|
| That no Zig package exists | yes | done, both queries returned 0 |
| That the ObjC runtime candidates are alive | yes | `gh api` gave stars and push dates |
| `translate-c` against SDK headers | no | no SDK on this host |
| Any link step | no | no macOS libraries |
| Runtime behaviour | no | needs macOS |

## 6. The overall dependency verdict

### 6.1 The list the port still needs from C

Four libraries, plus one conditional on the Wayland path.

| Library | Kind | Concrete blocker if a shim |
|---|---|---|
| `X11` and `Xext` | `translate-c`, rung 3 | none needed. Fallback if `baverman/zix11` proves unfit: headers and `.so` are on this host. |
| `xcb` with the `xfixes`, `xkb`, `shm` and `composite` extensions | `translate-c`, rung 3 | none needed. `HaraldWik/xcb-zig` does not generate these today, so `translate-c` is the only path. |
| `libwayland-client` | `translate-c`, rung 3 | none needed. Headers and `.so` are on this host. `ifreund/zig-wayland` supplies the generated Zig on top. |
| `EGL` | `translate-c`, rung 3 | **blocked on this host**: no `EGL/egl.h` and no `libEGL.so`. A package install is required before any binding can be built here. |
| `xkbcommon` | **not needed** | `LilithSemi/xkbcommon.zig` replaces it at rung 2. |

**No rung-4 hand-written C shim is required for any of them.** None of the
four sits behind a macro that `translate-c` cannot express, an opaque handle, a
callback with a non-representable type, or varargs. The only remaining question
for rung 4 would be GLX or EGL extension entry points, and `zig-gamedev/zopengl`
already takes those as a `LoaderFn`, so no shim is needed there either.

### 6.2 What the port takes from Zig

| Package | Pin | Role |
|---|---|---|
| `luxluth/goose` | `8c6ee3a984a3b314bb921e3f8f6428a51a6d93e1`, tag `v3.3.0` | D-Bus |
| `lalinsky/zio` | `2662fdc45997611b962b560c513c16963475a01b` | runtime and event source |
| `zig-gamedev/zopengl` | `eda87248c6fa190fbb5fe78fc84c5e28d6b2032e` | OpenGL bindings and loader |
| `baverman/zix11` | `3f9771d7920f6acf18b26c4756ca7768c8778436`, tag `0.9.0` | X11, if the design picks rung 2 |
| `LilithSemi/xkbcommon.zig` | `d11d8dd0867917180296aeebbcd2e0c0ed928863` | XKB |
| `LilithSemi/x11.zig` | `32b025025abfea98d2adc65df7e2bd156b45af34` | transitive for `xkbcommon.zig` |
| `ianprime0509/zig-xml` | `d73304c3d56d6331a0caca4d339607e7c740aab5` | transitive for both of the above |
| `ifreund/zig-wayland` | `3c6da94905ac1b27fe7792709e1b05cc55052d5a`, tag `v0.6.0` | Wayland protocol Zig |

Two of those pins sit in other people's `build.zig.zon` files. They are
reproduced here from the clones:

| Hash | Declared in |
|---|---|
| `x11-0.1.0-dfzXO3ABEgDh_aano5-90TqY5zHjGEPc1lw4dAy7l-Pg` | `LilithSemi__xkbcommon.zig/build.zig.zon`, field `.x11` |
| `xml-0.2.0-ZTbP35V4AgA_pFiWGWiBILJK7ifCCvj7mbiGfyMcEi2K` | `LilithSemi__x11.zig/build.zig.zon`, field `.xml` |

### 6.3 What the design document must decide

These are open, not resolved here.

| Question | Why it is open |
|---|---|
| goose `.poll` plus zio, or a small goose change? | The three gaps in section 3.1 all need a call. |
| `$AT_SPI_BUS_ADDRESS` required, or `GetAddress` at run time? | `bus.rs:43-51` does the second; goose `src/connection.zig:493-501` does the first. |
| `zix11` or `translate-c` of `Xlib`? | `zix11` is rung 2 and thin at 5 stars. |
| Vendor `xdg-shell.xml` or require `wayland-protocols`? | It is not installed here. |
| Install `libegl-dev` or accept an unbuildable EGL binding? | Section 4.3. |

## Appendix A. Commands, verbatim

```
zig version
# 0.16.0

gh api "search/repositories?q=<urlencoded>&per_page=30&page=1"
gh api repos/<owner>/<repo>

git ls-remote --tags --heads https://github.com/<owner>/<repo>.git
git clone --depth 1 --branch <ref> https://github.com/<owner>/<repo>.git <dest>

# inside a clone:
cat build.zig.zon
git rev-parse HEAD
git describe --tags --exact-match
find . -name '*.zig' -not -path './.git/*' -print0 | xargs -0 cat | wc -l
grep -rn --include=*.zig -E 'std\.Io' .
grep -rn --include=*.zig -E '@cImport|translate-c|root\.translate' .

zig fetch --global-cache-dir /tmp/scratch/ZigEcosystem/zcache \
  https://github.com/<owner>/<repo>/archive/<sha>.tar.gz

curl -sSL -w "\n[HTTP %{http_code} final=%{url_effective}]\n" https://pkg.machengine.org/zig/
curl -sSL "https://api.zigistry.dev/search/packages/?q=<term>&page=1&per_page=25&sort=stars&dir=desc"

pkg-config --list-all | grep -iE 'x11|xcb|wayland|egl|gl|xkb|atspi'
pkg-config --modversion <name>
ls /usr/lib64 | grep -E '^lib(EGL|GL|xkbcommon|atspi)'
ls /usr/include
```

## Appendix B. Artefacts left behind

All under `/tmp/scratch/ZigEcosystem/`.

| Path | What |
|---|---|
| `gh-search.log` | every GitHub search URL |
| `zigistry.log` | every Zigistry URL |
| `ls-remote.json` | every tag and head sha |
| `clones.json` | sha, ref, zon path, line counts, and the full text of each `build.zig.zon` that was read |
| `iomodel.json` | `std.Io` and `@cImport` hit counts |
| `final-table.json` | the section 2.2 data |
| `stars.json` | stars, push date, licence |
| `zig-fetch.log` | every `zig fetch` call and output |
| `fetch-results.json` | fetch exit codes |
| `translatec.json` | the `translate-c` attempts |

The 29 clones, the `zig fetch` cache and the `translate-c` output directories
were deleted after the measurements were written into this document. The
directory is now 96 KB. To repeat a measurement, re-clone at the commit in the
`Commit` column of section 2.2.

## Appendix C. What was not searched

Stated so the design document knows the limits of this list.

| Not searched | Why |
|---|---|
| GitHub code search API | It needs a different scope and returns no repository metadata. Only repository search was used. |
| SourceHut, Codeberg, GitLab | Zig packages on those hosts were found indirectly, through GitHub mirrors and Zigistry. A direct Codeberg search was not run. |
| `zigistry.dev` "programs" index | Only the `packages` index was queried. |
| Non-English sources | Not searched. |
| Packages published after 2026-10-04 | Cannot exist. Searches were run on that date. |
