Consumed by `docs/30-port-design.md` and `docs/40-plan.md`. Every claim below
comes from a command run on 2026-10-05 against goose v3.3.0 and the live a11y bus
on this node. Nothing in this document is a reading of the source alone. Where a
claim comes from reading the source, the file and line are given.

# 26 — goose v3.3.0 against the live a11y bus

## 0. Scope, host, and method

This document answers eight questions by experiment. The questions are about
what the port may assume, not about how goose is written.

| Item | Value |
|---|---|
| goose tree | `/tmp/scratch/goose`, tag `v3.3.0`, commit `8c6ee3a984a3b314bb921e3f8f6428a51a6d93e1` |
| zig | 0.16.0, release toolchain at `/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ` |
| scratch | `/tmp/scratch/goose-probe` |
| a11y bus address | `unix:path=/run/user/33156/at-spi/bus` |
| session bus | `unix:path=/run/user/33156/bus` |
| uid | 33156 |

The host facts come from the integration owner and were re-checked here:

```
$ busctl --user call org.a11y.Bus /org/a11y/bus org.a11y.Bus GetAddress
s "unix:path=/run/user/33156/at-spi/bus"
```

```
$ busctl --address=unix:path=/run/user/33156/at-spi/bus list
NAME                      PID PROCESS         USER     CONNECTION UNIT                SESSION DESCRIPTION
:1.6                    24801 at-spi2-registr user :1.6       user@33156.service  -       -
:1.8                    19017 busctl           user :1.8       session-77176.scope 77176   -
org.a11y.atspi.Registry 24801 at-spi2-registr user :1.6       user@33156.service  -       -
org.freedesktop.DBus    55300 at-spi-bus-laun user -          user@33156.service  -       -
```

Only the registry and the bus driver are on the a11y bus. There is no AT-SPI
application. Section 4 shows what that means for signal tests.

The probe is one executable with one mode per question. Modes: `session`,
`getaddr`, `fallback`, `calls`, `signals`, `emit`, `pollfd`, `ziofd`. The same
file produced every output below.

Two trees were used, and the difference is stated in each section:

- `clean/` pins goose by URL and hash. It is pristine goose v3.3.0.
- The main probe uses `goose-local/`, which is the same fetched tree with one
  added block of four lines in `src/connection.zig`. Section 7 explains why and
  shows the block. Sections 2 to 6 run the same code both ways with the same
  result.

## 1. Does the pin fetch under Zig 0.16.0? PASS

`zig fetch` writes the dependency into `build.zig.zon` and prints nothing on
success. The first attempt failed because the package had no fingerprint:

```
$ zig fetch --save=goose "https://github.com/luxluth/goose/archive/refs/tags/v3.3.0.tar.gz"
anyzig: .minimum_zig_version '0.16.0' pulled from '/tmp/scratch/goose-probe/build.zig.zon'
anyzig: appdata '~/.local/share/anyzig'
anyzig: zig '0.16.0' already exists at '/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ'
build.zig.zon:1:2: error: missing top-level 'fingerprint' field; suggested value: 0xa6abf4fbe4a63fd2
.{
 ^
EXIT=2
```

The command that produced the hash, run again after the fingerprint was added:

```
$ zig fetch --save=goose "https://github.com/luxluth/goose/archive/refs/tags/v3.3.0.tar.gz"
anyzig: .minimum_zig_version '0.16.0' pulled from '/tmp/scratch/goose-probe/build.zig.zon'
anyzig: appdata '~/.local/share/anyzig'
anyzig: zig '0.16.0' already exists at '/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ'
EXIT=0
```

The two lines that work:

```zig
.goose = .{
    .url = "https://github.com/luxluth/goose/archive/refs/tags/v3.3.0.tar.gz",
    .hash = "goose-3.3.0-e9MzMIEpBACANYPKd-lGDjoxFHcbYTKmfMWA4c0XK_wZ",
},
```

The toolchain reports 0.16.0 and not another version:

```
$ zig version
anyzig: .minimum_zig_version '0.16.0' pulled from '/tmp/scratch/goose-probe/build.zig.zon'
anyzig: appdata '~/.local/share/anyzig'
anyzig: zig '0.16.0' already exists at '/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ'
0.16.0
```

The check that matters is a build from an empty package directory. `clean/` held
only `build.zig`, `build.zig.zon` and `src/main.zig`. There was no `zig-pkg`
directory:

```
$ ls clean/zig-pkg
ls: cannot access 'clean/zig-pkg': No such file or directory
```

`clean/build.zig.zon` pinned goose by URL and hash and nothing else. The build
fetched, unpacked and compiled:

```
$ zig build --summary all
anyzig: .minimum_zig_version '0.16.0' pulled from '/tmp/scratch/goose-probe/clean/build.zig.zon'
anyzig: appdata '~/.local/share/anyzig'
anyzig: zig '0.16.0' already exists at '/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ'
Build Summary: 3/3 steps succeeded
install success
+- install pinned success
   +- compile exe pinned Debug native success 1s MaxRSS:200M

EXIT=0
```

```
$ ls zig-pkg
goose-3.3.0-e9MzMIEpBACANYPKd-lGDjoxFHcbYTKmfMWA4c0XK_wZ
```

```
$ ./zig-out/bin/pinned
pinned goose built and ran; BusType=Accessibility
zig version in use: 0.16.0
EXIT=0
```

`clean/src/main.zig`, in full:

```zig
const std = @import("std");
const goose = @import("goose");

pub fn main(init: std.process.Init) !void {
    var conn = try goose.Connection.init(init.gpa, .Session, init.io, init.environ_map);
    defer conn.close();
    std.debug.print("pinned goose built and ran; BusType={s}\n", .{@tagName(@as(goose.BusType, .Accessibility))});
    std.debug.print("zig version in use: {s}\n", .{@import("builtin").zig_version_string});
}
```

`goose/build.zig.zon:6` asks for `.minimum_zig_version = "0.16.0"`, so the
package manager and the anyzig shim agree. Tag `v4.0.0` of goose is not
reachable this way. It requires 0.17.0. The whole experiment runs on v3.3.0.

**What the design may assume.** The two lines in `build.zig.zon` are final. No
fork is needed to compile goose. `zig fetch` writes them and `zig build`
reproduces them from a clean tree.

## 2. Does goose build and run at all under 0.16.0? PASS

The probe constructs a session-bus connection and makes one method call. The
mode is `session`, and it is 15 lines:

```zig
if (std.mem.eql(u8, mode, "session")) {
    var conn = try Connection.init(allocator, .Session, init.io, init.environ_map);
    defer conn.close();
    std.debug.print("[session] connected, getFd()={d}\n", .{conn.getFd()});
    const reply = try conn.methodCall(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "GetId",
        null,
        &.{},
    );
    var dec = message.BodyDecoder.fromMessage(allocator, reply);
    const id = try dec.decode(GStr);
    std.debug.print("org.freedesktop.DBus.GetId -> \"{s}\"\n", .{id.s});
    dumpReply(&conn, "session GetId", reply);
    return;
}
```

`init` is `std.process.Init`, so `init.gpa`, `init.io` and `init.environ_map`
come from the 0.16 process model. `Connection.init` takes those three plus a
`BusType` (`connection.zig:469-471`). No wrapper, no shim, no C.

```
$ ./zig-out/bin/probe session
mode = session
[session] connected, getFd()=3
org.freedesktop.DBus.GetId -> "69d8a47d46929e4d18223abd3bb231d6"
[session GetId] message_type=MethodReturn serial=4294967295 body_len=37 fds=0
  REPLY_SERIAL= 2
  SENDER      = "org.freedesktop.DBus"
  DESTINATION = ":1.129"
  SIGNATURE   = "s"
  BODY_RAW    =  \x00\x00\x0069d8a47d46929e4d18223abd3bb231d6\x00
  BODY_HEX    = 20000000363964386134376434363932396534643138323233616264336262323331643600
```

`serial=4294967295` is the reply's own serial, which goose sets to
`0xFFFFFFFF` for inbound messages. The body decodes to the string
`69d8a47d46929e4d18223abd3bb231d6`, which is this probe's unique name on the
session bus. The `0x20` length prefix and the trailing `0x00` are correct D-Bus
string framing.

The build itself:

```
$ zig build --summary all
Build Summary: 3/3 steps succeeded
install success
+- install probe success
   +- compile exe probe Debug native success 1s MaxRSS:201M
```

**What the design may assume.** A goose connection constructs and answers a
method call in a Debug build. `std.process.Init` is the only entry point the
adapter needs to write.

## 3. Can goose reach the live a11y bus? PASS, with one required step

goose has no `initFromAddress`. The only entry points are:

```zig
// connection.zig:469
pub fn init(allocator: std.mem.Allocator, bus_type: BusType, io: std.Io, vars: *std.process.Environ.Map) !Connection
// connection.zig:474
pub fn initWithBackend(allocator: std.mem.Allocator, bus_type: BusType, io: std.Io, vars: *std.process.Environ.Map, backend: Backend) !Connection
// connection.zig:128-135
pub const BusType = enum { Session, System, Accessibility };
```

The bus address comes from the `Environ.Map` the caller passes, not from the
process environment. `connection.zig:493-501`:

```zig
.Accessibility => {
    if (vars.get("AT_SPI_BUS_ADDRESS")) |addr| {
        socket_paths = .init(addr);
    } else {
        const uid = std.posix.system.getuid();
        allocated_path = try std.fmt.allocPrint(allocator, "unix:path=/run/user/{d}/at-spi/bus_0", .{uid});
        socket_paths = .init(allocated_path.?);
    }
},
```

So goose can be pointed at an explicit address, through the
`AT_SPI_BUS_ADDRESS` key of the map it is handed. The address parser,
`SocketIterator` at `connection.zig:1451-1475`, understands `unix:path=` only.

The exact address string, read by goose from the session bus:

```
$ ./zig-out/bin/probe getaddr
mode = getaddr
[session] connected to session bus, getFd()=3
[org.a11y.Bus.GetAddress] message_type=MethodReturn serial=58 body_len=41 fds=0
  DESTINATION = ":1.137"
  SIGNATURE   = "s"
  REPLY_SERIAL= 2
  SENDER      = ":1.9"
  BODY_RAW    = $\x00\x00\x00unix:path=/run/user/33156/at-spi/bus\x00
  BODY_HEX    = 24000000756e69783a706174683d2f72756e2f757365722f33333135362f61742d7370692f62757300
```

The leading `24 00 00 00` is the D-Bus length prefix for a 36-byte string.
`24` is hex for 36. The trailing `00` is the string terminator.

The code that uses it:

```zig
const addr = try queryA11yAddress(allocator, init.io, init.environ_map);
try init.environ_map.put("AT_SPI_BUS_ADDRESS", addr);
var a11y = try connectA11y(allocator, init.io, init.environ_map, .threaded);
defer a11y.close();
```

```zig
fn queryA11yAddress(allocator: std.mem.Allocator, io: std.Io, vars: *std.process.Environ.Map) ![]u8 {
    var conn = try Connection.init(allocator, .Session, io, vars);
    defer conn.close();
    const reply = try conn.methodCall(
        "org.a11y.Bus",
        "/org/a11y/bus",
        "org.a11y.Bus",
        "GetAddress",
        null,
        &.{},
    );
    var dec = message.BodyDecoder.fromMessage(allocator, reply);
    const addr = try dec.decode(GStr);
    const copy = try allocator.dupe(u8, addr.s);
    dumpReply(&conn, "org.a11y.Bus.GetAddress", reply);
    return copy;
}
```

The rest of the same run proves the connection is on the a11y bus and not on
the session bus. `ListNames` on the a11y bus shows the registry:

```
AT-SPI address string from org.a11y.Bus.GetAddress = "unix:path=/run/user/33156/at-spi/bus"
put AT_SPI_BUS_ADDRESS=unix:path=/run/user/33156/at-spi/bus into the Environ.Map handed to goose
a11y bus connected, getFd()=3
names on the a11y bus: 4
  - org.freedesktop.DBus
  - :1.6
  - :1.57
  - org.a11y.atspi.Registry
[a11y ListNames] message_type=MethodReturn serial=4294967295 body_len=84 fds=0
  REPLY_SERIAL= 2
  SENDER      = "org.freedesktop.DBus"
  DESTINATION = ":1.57"
  SIGNATURE   = "as"
  BODY_HEX    = 50000000140000006f72672e667265656465736b746f702e4442757300000000040000003a312e3600000000050000003a312e3537000000170000006f72672e613131792e61747370692e526567697374727900
```

The hard-coded fallback path is wrong on this host. The fallback builds
`bus_0`, but the real socket is `bus`:

```
$ ls -la /run/user/33156/at-spi/
srwxr-xr-x 1 user mi19 0 Oct  4 23:54 bus
```

With `AT_SPI_BUS_ADDRESS` removed from the map, goose fails:

```
$ ./zig-out/bin/probe fallback
mode = fallback
AT_SPI_BUS_ADDRESS present after removal: false
fallback connect .Accessibility failed: error.FileNotFound
connection.zig:497-500 built "unix:path=/run/user/33156/at-spi/bus_0"
```

**What the design may assume.** The port must always set `AT_SPI_BUS_ADDRESS`
in the map it passes. It must never rely on goose's fallback path. One
connection is enough: the session bus is only needed for the `GetAddress`
call in section 6.

## 4. Can goose subscribe to a signal on the a11y bus? PASS

Two facts, both observed.

First, nothing emits `org.a11y.atspi.Event.Object.Event` on this host. The
subscription itself succeeds. With the bus idle for six seconds, no signal
arrives:

```
$ ./zig-out/bin/probe signals
mode = signals
a11y bus connected, getFd()=3
AddMatch sent: type='signal',interface='org.a11y.atspi.Event.Object'
AddMatch sent: type='signal',interface='org.a11y.atspi.Registry'
3 signal handlers registered; waiting 6 s
signal_hits = 0
```

Both `AddMatch` calls returned without error. `AddMatch` is
`connection.zig:1064-1077`, and it ignores the reply body, so a rejection would
be silent. The proof that the match rule took effect is the second run.

Second, delivery works. The registry emits
`org.a11y.atspi.Registry.EventListenerDeregistered` whenever a client leaves the
a11y bus. A second probe process connects and exits at T+2 s:

```
$ ./zig-out/bin/probe signals > signals.log 2>&1 & SP=$!
$ sleep 2
$ ./zig-out/bin/probe getaddr > /dev/null 2>&1
$ wait $SP; cat signals.log
mode = signals
a11y bus connected, getFd()=3
AddMatch sent: type='signal',interface='org.a11y.atspi.Event.Object'
AddMatch sent: type='signal',interface='org.a11y.atspi.Registry'
3 signal handlers registered; waiting 6 s
  >>> SIGNAL interface=org.a11y.atspi.Registry member=EventListenerDeregistered
      raw body = \x05\x00\x00\x00:1.53\x00\x00\x00\x00\x00\x00\x00\x00
signal_hits = 1
```

The body is a `ss` struct. The first string is the unique name `:1.53`, the
client that just left. The second is empty.

The same `busctl monitor` run that shows the signal on the wire:

```
$ busctl --address=unix:path=/run/user/33156/at-spi/bus monitor org.a11y.atspi.Registry
‣ Type=signal  Endian=l  Flags=1  Version=1 Cookie=43  Timestamp="Sun 2026-10-04 22:20:25.333050 UTC"
  Sender=:1.6  Path=/org/a11y/atspi/registry  Interface=org.a11y.atspi.Registry  Member=EventListenerDeregistered
  MESSAGE "ss" {
          STRING ":1.21";
          STRING "";
  };
```

Third, a synthetic peer can emit `org.a11y.atspi.Event.Object.Event` on the
a11y bus, and goose receives its own signal. The peer owns a name, then sends
a `Signal` message built by hand:

```zig
try a11y.requestName("org.zaccesskit.GooseProbe");
try a11y.addMatch("type='signal',interface='org.a11y.atspi.Event.Object'");
try a11y.registerSignalHandler("org.a11y.atspi.Event.Object", "Event", onSignal, null);

const serial = a11y.nextSerial();
const header = core.MessageHeader{
    .message_type = .Signal,
    .flags = 0,
    .proto_version = 1,
    .body_length = 0,
    .serial = serial,
    .header_fields = &.{
        .{ .code = .Path, .value = .{ .Path = "/org/a11y/atspi/accessible/root" } },
        .{ .code = .Interface, .value = .{ .Interface = "org.a11y.atspi.Event.Object" } },
        .{ .code = .Member, .value = .{ .Member = "Event" } },
    },
};
try a11y.sendMessage(core.Message.new(header, &.{}));
```

```
$ ./zig-out/bin/probe emit
mode = emit
requested name org.zaccesskit.GooseProbe on the a11y bus
sent org.a11y.atspi.Event.Object.Event from serial 4; waiting 3 s
  >>> SIGNAL interface=org.a11y.atspi.Event.Object member=Event
      raw body = 
signal_hits = 1
```

`requestName` is `connection.zig:620-666`. `sendMessage` is
`connection.zig:669-694` and it packs the message itself. A real
`org.a11y.atspi.Event.Object` signal body has the signature
`siiva{sv}`, that is five arguments. The test peer must build that body
before it is useful for translation tests.

**The five arguments, named from the specification.** All 57 signals in
the seven `org.a11y.atspi.Event.*` interfaces of the AT-SPI2 reference
XML declare the same five arguments, in this order:

| # | Type | Name in the XML | What it is |
|---|------|-----------------|------------|
| 0 | `s` | per signal, unnamed in 49 of 57 | The event's string detail |
| 1 | `i` | per signal, unnamed in 49 of 57 | The event's first integer detail |
| 2 | `i` | unnamed in 52 of 57 | The event's second integer detail |
| 3 | `v` | per signal, unnamed in 53 of 57 | The event's variant detail |
| 4 | `a{sv}` | `properties` in 57 of 57 | Reserved, and currently empty |

The reason the first four carry no fixed name is in `xml/Event.xml:4-16`:
"For historical reasons, all events include a string, two integers, and
a variant. The meaning of these values will depend on the specific
event, and they may be unused, in which case an empty string or a value
of 0 should be sent." The same comment says the dictionary "is reserved
for future use. Currently, this dictionary should be empty."

Only argument 4 has one name across the whole file. Positions 0 to 3 are
named per signal, and are unnamed in most. Position 0 takes `property`,
`name`, `detail`, `state` or `operation`. Position 1 takes `x`,
`enabled`, `index_in_parent`, `start_pos`, `position`, `mouse_x` or
`previous_modifiers`. Position 2 takes `y`, `length`, `mouse_y` or
`current_modifiers`. Position 3 takes `child`, `value` or `text`. An
encoder must not read a name out of position 0 to 3 and assume that
name holds for every signal.

**The object path, the interface, the signal name and the sender are not
in the body.** They are D-Bus message *header* fields: `PATH`,
`INTERFACE`, `MEMBER` and `SENDER`. The bus daemon adds `SENDER`, so a
sender cannot state its own unique name in the body. The synthetic peer
above already carries four of them, as header fields.

**No member of that interface is named `Event`.**
`org.a11y.atspi.Event.Object` declares 22 signals, and the reference XML
contains no `<signal name="Event">` anywhere. AccessKit maps its
`ObjectEvent` variants onto the real names
(`UP/adapters/unix/src/atspi/bus.rs:271-281`). `org.a11y.atspi.Event.Object.Event`
is therefore not a signal the port can send or receive, and the member
name in the snippet above is arbitrary. The `addMatch` rule is still
correct, because it matches on interface alone.

**What the design may assume.** Match rules, handler registration and
delivery all work on the a11y bus. Signal delivery tests cannot rely on a live
application, because none is on this bus. The test harness needs a synthetic
peer, and goose can build one with `requestName` plus `sendMessage`.

## 5. Can goose call a method on the registry? PASS

The path named in the question, `/org/a11y/atspi/null`, carries no interface
on this registry. The reply is a normal D-Bus error message, and goose returns
it as a message instead of raising an error:

```
$ ./zig-out/bin/probe calls
mode = calls

--- call 1: org.a11y.atspi.Registry.GetChildren at /org/a11y/atspi/null (the path the plan named) ---
[Registry.GetChildren(/org/a11y/atspi/null)] message_type=Error serial=65 body_len=97 fds=0
  DESTINATION = ":1.51"
  ERROR_NAME  = "org.freedesktop.DBus.Error.UnknownMethod"
  REPLY_SERIAL= 2
  SIGNATURE   = "s"
  SENDER      = ":1.6"
  BODY_RAW    = \x00\x00\x00Method "GetChildren" with signature "" on interface "org.a11y.atspi.Registry" doesn't exist\x0A\x00
  BODY_HEX    = 5c0000004d6574686f6420224765744368696c6472656e222077697468207369676e6174757265202222206f6e20696e7465726661636520226f72672e613131792e61747370692e52656769737472792220646f65736e27742065786973740a00
```

The same is true for `org.freedesktop.DBus.Properties.Get` at that path:

```
--- call 3: org.freedesktop.DBus.Properties.Get org.a11y.atspi.Socket at /org/a11y/atspi/null ---
[Properties.Get(Socket)] message_type=Error serial=67 body_len=99 fds=0
  DESTINATION = ":1.51"
  ERROR_NAME  = "org.freedesktop.DBus.Error.UnknownMethod"
  REPLY_SERIAL= 4
  SIGNATURE   = "s"
  SENDER      = ":1.6"
  BODY_RAW    = ^\x00\x00\x00Method "Get" with signature "ss" on interface "org.freedesktop.DBus.Properties" doesn't exist\x0A\x00
  BODY_HEX    = 5e0000004d6574686f642022476574222077697468207369676e61747572652022737322206f6e20696e7465726661636520226f72672e667265656465736b746f702e444275732e50726f706572746965732220646f65736e27742065786973740a00
```

`busctl` returns the same two errors, so this is the registry, not goose:

```
$ busctl --address=unix:path=/run/user/33156/at-spi/bus call org.a11y.atspi.Registry /org/a11y/atspi/null org.a11y.atspi.Registry GetChildren
Call failed: Method "GetChildren" with signature "" on interface "org.a11y.atspi.Registry" doesn't exist
```

The registry object is at `/org/a11y/atspi/registry`. `GetRegisteredEvents`
succeeds there and returns an empty array. This is the empty reply the question
asks for:

```
--- call 2: org.a11y.atspi.Registry.GetRegisteredEvents at /org/a11y/atspi/registry ---
[Registry.GetRegisteredEvents] message_type=MethodReturn serial=66 body_len=8 fds=0
  DESTINATION = ":1.51"
  REPLY_SERIAL= 3
  SIGNATURE   = "a(ss)"
  SENDER      = ":1.6"
  BODY_RAW    = \x00\x00\x00\x00\x00\x00\x00\x00
  BODY_HEX    = 0000000000000000
```

Eight zero bytes are an empty `a(ss)`: the four-byte array length, then the
alignment padding to the element alignment of eight.

The registry exposes only three methods and two signals. Goose read the XML
through `Introspect`, which is how the port will learn the AT-SPI surface:

```
--- call 4: Introspect at /org/a11y/atspi/registry ---
[Introspect(registry)] XML = <?xml version="1.0"?>
<node name="/org/a11y/atspi/registry">
<interface name="org.a11y.atspi.Registry">    <method name="RegisterEvent">      <arg direction="in" name="event" type="s" />      <arg direction="in" name="properties" type="as" />      <arg direction="in" name="app_bus_name" type="s" />    </method>    <method name="DeregisterEvent">      <arg direction="in" name="event" type="s" />    </method>    <method name="GetRegisteredEvents">      <arg direction="out" name="events" type="a(ss)" />      <annotation name="org.qtproject.QtDBus.QtTypeName.Out0" value="QSpiEventListenerArray" />    </method>    <signal name="EventListenerRegistered">      <arg name="bus" type="s" />      <arg name="path" type="s" />    </signal>    <signal name="EventListenerDeregistered">      <arg name="bus" type="s" />      <arg n…
```

The XML is truncated by the output limit of the tool that captured it. The same
table from `busctl` is complete:

```
$ busctl --address=unix:path=/run/user/33156/at-spi/bus introspect org.a11y.atspi.Registry /org/a11y/atspi/registry
NAME                       TYPE      SIGNATURE RESULT/VALUE FLAGS
org.a11y.atspi.Registry    interface -         -            -
.DeregisterEvent           method    s         -            -
.GetRegisteredEvents       method    -         a(ss)        -
.RegisterEvent             method    sass      -            -
.EventListenerDeregistered signal    ss        -            -
.EventListenerRegistered   signal    ss        -            -
```

The object tree of the registry, which shows that no accessible objects exist:

```
$ busctl --address=unix:path=/run/user/33156/at-spi/bus tree org.a11y.atspi.Registry
└─ /org
  └─ /org/a11y
    └─ /org/a11y/atspi
      ├─ /org/a11y/atspi/accessible
      │ └─ /org/a11y/atspi/accessible/root
      ├─ /org/a11y/atspi/cache
      └─ /org/a11y/atspi/registry
```

**What the design may assume.** Method calls, `Introspect` and error replies
work. The port must use `/org/a11y/atspi/registry` for the registry interface,
not `/org/a11y/atspi/null`. An empty array reply is a normal success. The port
must also check `msg.header.message_type` for `.Error`, because `methodCall`
returns errors as values.

## 6. What does goose do with the a11y bus address? FAIL. The port must do it

goose does not model the two step. A search of the whole package finds no
reference to `org.a11y.Bus` and no call to `GetAddress`:

```
$ grep -rn "org\.a11y\.Bus\|GetAddress" /tmp/scratch/goose/src
(no match)
```

The only accessibility code is the enum member and the environment lookup:

```
$ grep -rn "Accessibility" /tmp/scratch/goose/src
/tmp/scratch/goose/src/connection.zig:133:    /// The accessibility bus (AT-SPI).
/tmp/scratch/goose/src/connection.zig:134:    Accessibility,
/tmp/scratch/goose/src/connection.zig:466:    /// `bus_type`: The type of bus to connect to (.Session, .System, or .Accessibility).
```

goose reads one environment variable and stops. The port owns the two step, and
the code is the `queryA11yAddress` function from section 3. The port must:

1. Open a `.Session` connection to the session bus.
2. Call `org.a11y.Bus` at `/org/a11y/bus`, member `GetAddress`.
3. Decode the reply as a `GStr`.
4. Put the result into `Environ.Map` under `AT_SPI_BUS_ADDRESS`.
5. Close the session connection and open the `.Accessibility` one.

Step 5 is not proven as necessary by this document. `[INFERENCE]` The session
connection can stay open. It only needs to answer one call.

**What the design may assume.** goose contributes no a11y discovery. The port
owns all five steps and needs a session-bus connection for step 2.

## 7. The fd question. PASS, after a four-line change to goose

This is the answer the port design needs, so it is given in full.

### 7.1 What goose exposes

Everything the external loop needs is public, and nothing more:

| Item | Where | Signature |
|---|---|---|
| `getFd` | `connection.zig:292-294` | `pub fn getFd(self: *const Connection) std.posix.fd_t` |
| `hasDataToRead` | `connection.zig:297-308` | `pub fn hasDataToRead(self: *Connection) bool` |
| `dispatch` | `connection.zig:312-341` | `pub fn dispatch(self: *Connection) !bool` |
| `Backend.poll` | `connection.zig:122-125` | `enum { threaded, poll }` |
| `serve` rejects poll | `connection.zig:891-894` | `return error.InvalidBackend` |
| `io` field | `connection.zig:268` | `io: std.Io` |

`.poll` starts no thread. `.threaded` starts two, in `ensureWorkersStarted`
at `connection.zig:863-881`. So `.poll` is the only backend that keeps one
threading model in the process.

`hasDataToRead` does not use `std.Io`. It calls `std.posix.poll(&pfd, 0)` at
`connection.zig:306`, a zero-timeout syscall on the caller's thread.

The reader does not use `std.Io` either. `SocketReader.recvWithIovecs` at
`connection.zig:203-260` calls `std.posix.system.recvmsg(self.fd, &msg, flags)`
at `connection.zig:221`, a raw blocking syscall. It folds `EAGAIN` into
`error.ReadFailed` at `connection.zig:188-190`. There is no retry and no await.

### 7.2 What a zio runtime gives

zio already ships a `std.Io` implementation. It is not reachable through the
module root, which is the first obstacle:

```
$ git -C ~/zio show 2662fdc45997611b962b560c513c16963475a01b:src/io.zig | grep -n "pub fn fromRuntime\|pub const Mode\|pub fn toRuntime"
118:pub const Mode = enum { regular, blocking };
138:pub fn fromRuntime(rt: *Runtime, mode: Mode) Io {
146:pub fn toRuntime(io: Io) *Runtime {
```

`zio.zig:101` re-exports only `debug_io`. Adding `src/io.zig` as a second
module fails, because Zig forbids one file in two modules:

```
zig-pkg/zio-0.18.0-.../src/zio.zig:1:1: error: file exists in modules 'zio_io' and 'zio'
zig-pkg/zio-0.18.0-.../src/zio.zig:1:1: note: files must belong to only one module
zig-pkg/zio-0.18.0-.../src/zio.zig:1:1: note: file is the root of module 'zio_io'
zig-pkg/zio-0.18.0-.../src/zio.zig:101:30: note: file is imported here by the root of module 'zio'
pub const debug_io = @import("io.zig").debug_io;
```

So the probe uses a copy of the fetched tree with three re-export lines added
to `zio.zig`, marked `PROBE-ONLY ADDITION` in the file. The lines change no
behaviour:

```zig
pub const fromRuntime = @import("io.zig").fromRuntime;
pub const toRuntime = @import("io.zig").toRuntime;
pub const IoMode = @import("io.zig").Mode;
```

### 7.3 First run against a zio-backed `std.Io`: FAIL

The task builds the connection with `.poll` and the `std.Io` from
`fromRuntime`. It fails during the SASL handshake:

```
$ ./zig-out/bin/probe ziofd
mode = ziofd
zio std.Io: vtable=Io.VTable@14fca30, userdata=*anyopaque@7f002c173001
zio Runtime recovered by zio.toRuntime: runtime.Runtime@7f002c173000
same Runtime object: true
[zio task] entered, std.Io.vtable=Io.VTable@14fca30
[zio task] zio.sleep(50ms) completed; loop advanced 50071535 ns
[zio task] socket mode through the zio-backed std.Io:
  [zio std.Io] connect(/run/user/33156/at-spi/bus) ok, fd=6, O_NONBLOCK=true (raw flags 0x802)
[main] socket mode through the default std.Io:
  [default std.Io] connect(/run/user/33156/at-spi/bus) ok, fd=6, O_NONBLOCK=false (raw flags 0x2)
error(zio): Group task failed with error: error.ReadFailed
```

`zio.sleep` completed, so zio's event loop is the loop that ran. The cause is
the socket mode. zio opens the socket with `.nonblocking = true`
(`zio/src/net.zig:912`) and never restores blocking mode. The default `std.Io`
leaves the descriptor blocking. goose's raw `recvmsg` then gets `EAGAIN`, and
`connection.zig:189-190` turns that into `error.ReadFailed`.

### 7.4 The change, and the second run: PASS

Four lines after `const socket = try unix_addr.connect(io);` at
`connection.zig:514`:

```zig
{
    const fl = std.posix.system.fcntl(socket.socket.handle, std.posix.F.GETFL, @as(usize, 0));
    const mask = @as(@TypeOf(fl), 1 << 11); // 04000 octal on Linux
    const cleared: usize = @intCast(fl & ~mask);
    _ = std.posix.system.fcntl(socket.socket.handle, std.posix.F.SETFL, cleared);
}
```

With that block the same task runs end to end. A second probe process makes the
registry emit a signal at T+3 s, and the zio task receives it:

```
$ ./zig-out/bin/probe ziofd > ziofd.log 2>&1 & ZP=$!
$ sleep 3
$ ./zig-out/bin/probe getaddr > /dev/null 2>&1
$ wait $ZP; cat ziofd.log
mode = ziofd
zio std.Io: vtable=Io.VTable@14fca30, userdata=*anyopaque@7f177d133001
zio Runtime recovered by zio.toRuntime: runtime.Runtime@7f177d133000
same Runtime object: true
[zio task] entered, std.Io.vtable=Io.VTable@14fca30
[zio task] zio.sleep(50ms) completed; loop advanced 50166354 ns
[zio task] socket mode through the zio-backed std.Io:
  [zio std.Io] connect(/run/user/33156/at-spi/bus) ok, fd=6, O_NONBLOCK=true (raw flags 0x802)
[main] socket mode through the default std.Io:
  [default std.Io] connect(/run/user/33156/at-spi/bus) ok, fd=6, O_NONBLOCK=false (raw flags 0x2)
[zio task] goose a11y connected on a zio-backed std.Io, backend=poll getFd()=6
[zio task] GetId -> "4725ccab70320e8d629d890d0b95473b"
[zio task GetId] message_type=MethodReturn serial=4294967295 body_len=37 fds=0
  REPLY_SERIAL= 2
  SENDER      = "org.freedesktop.DBus"
  DESTINATION = ":1.49"
  SIGNATURE   = "s"
  BODY_RAW    =  \x00\x00\x004725ccab70320e8d629d890d0b95473b\x00
[zio task] std.posix.poll(goose fd, 0) -> 1
[zio task] goose.hasDataToRead() = true
  >>> SIGNAL interface=org.a11y.atspi.Registry member=EventListenerDeregistered
      raw body = \x05\x00\x00\x00:1.50\x00\x00\x00\x00\x00\x00\x00\x00
[zio task] conn.dispatch() = true
zio task finished, signal_hits = 1
```

The task, in full:

```zig
fn zioTask(allocator: std.mem.Allocator, vars: *std.process.Environ.Map, io: std.Io, default_io: std.Io) !void {
    const zio = @import("zio");

    const t0 = zio.now();
    try zio.sleep(.fromMilliseconds(50));
    std.debug.print("[zio task] zio.sleep(50ms) completed; loop advanced {d} ns\n", .{zio.now().toNanoseconds() - t0.toNanoseconds()});

    const raw_path = "/run/user/33156/at-spi/bus";
    describeSocket(io, "zio std.Io", raw_path);
    describeSocket(default_io, "default std.Io", raw_path);

    var conn = try Connection.initWithBackend(allocator, .Accessibility, io, vars, .poll);
    defer conn.close();

    const reply = try conn.methodCall(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "GetId",
        null,
        &.{},
    );

    try conn.addMatch("type='signal',interface='org.a11y.atspi.Registry'");
    try conn.registerSignalHandler("org.a11y.atspi.Registry", "EventListenerDeregistered", onSignal, null);

    try zio.sleep(.fromSeconds(5));
    var pfd = [1]std.posix.pollfd{.{ .fd = conn.getFd(), .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&pfd, 0);
    std.debug.print("[zio task] std.posix.poll(goose fd, 0) -> {d}\n", .{n});
    std.debug.print("[zio task] goose.hasDataToRead() = {}\n", .{conn.hasDataToRead()});
    const dispatched = conn.dispatch();
    std.debug.print("[zio task] conn.dispatch() = {}\n", .{dispatched});
}
```

The mode that builds the runtime, in full:

```zig
const zio = @import("zio");
const addr = try queryA11yAddress(allocator, init.io, init.environ_map);
try init.environ_map.put("AT_SPI_BUS_ADDRESS", addr);

var rt = try zio.Runtime.init(init.gpa, .{});
defer rt.deinit();

const zio_io = zio.fromRuntime(rt, .blocking);

var group: zio.Group = .init;
defer group.cancel();
try group.spawn(zioTask, .{ allocator, init.environ_map, zio_io, init.io });
try group.wait();
```

### 7.5 The same question without zio

`pollfd` does the same thing on the default `std.Io`. A method call works in
`.poll` mode, and `poll` on the raw fd is the readiness wait:

```
$ ./zig-out/bin/probe pollfd
mode = pollfd
backend=poll getFd()=3
[poll-mode GetId] message_type=MethodReturn serial=4294967295 body_len=37 fds=0
  REPLY_SERIAL= 2
  SENDER      = "org.freedesktop.DBus"
  SIGNATURE   = "s"
  BODY_RAW    =  \x00\x00\x004725ccab70320e8d629d890d0b95473b\x00
std.posix.poll on fd 3 for 3000 ms
poll returned 0, revents=0
dispatch() = false
signal_hits = 0
```

### 7.6 The answer

The port does not run two event loops. goose `.poll` starts no thread, and the
only loop in the process is zio's.

goose can be adapted to a zio-backed `std.Io` by passing
`zio.fromRuntime(rt, .blocking)` as the `io` argument. That is a parameter
swap, not a fork. Three conditions apply:

1. The socket must be blocking. Four lines in goose fix it, and the probe
   proves the fix.
2. The port must pump `dispatch()` after the fd becomes readable. goose offers
   no callback and no registration. The port polls `getFd()` itself.
3. `methodCall` blocks the calling thread. In `.poll` mode `callWithFds` at
   `connection.zig:1404-1433` reads in a `while (true)` loop until the reply
   arrives. Inside a zio task that parks the executor. Every D-Bus call must
   run in `zio.spawnBlocking`, or goose needs an asynchronous call API. This
   document did not measure the cost of condition 3.

`hasDataToRead` and `dispatch` both bypass `std.Io`, so neither can await
inside a task. `zio.ev.NetPoll` at `zio/src/ev/completion.zig` and
`zio.os.net.poll` at `zio/src/os/net.zig:116` are the two ways zio offers to
wait on a raw descriptor. Which one the port uses is a design decision this
document does not make.

**What the design may assume.** One event loop. goose runs inside it. Two small
upstream changes stand between goose v3.3.0 and a zio-backed `std.Io`: the
`O_NONBLOCK` reset in section 7.4 and a re-export of `fromRuntime` from zio.

## 8. Verdict

| # | Question | Result | What the design may assume |
|---|---|---|---|
| 1 | Pin fetches under Zig 0.16.0 | PASS | The `.url` and `.hash` in section 1 are final. `zig build` pulls and compiles goose v3.3.0 from a clean tree. |
| 2 | Builds and runs | PASS | `Connection.init` plus `methodCall` work on the default `std.Io`. `std.process.Init` is the only entry point needed. |
| 3 | Reaches the live a11y bus | PASS, with a required step | `BusType.Accessibility` plus `AT_SPI_BUS_ADDRESS` reaches `unix:path=/run/user/33156/at-spi/bus`. The port must set the variable. The `bus_0` fallback is wrong here. |
| 4 | Subscribes to a signal | PASS | `addMatch` and `registerSignalHandler` deliver real a11y signals. No AT-SPI application is on this bus, so tests need a synthetic peer. |
| 5 | Calls a registry method | PASS | Calls, `Introspect` and error replies all work. The registry object is `/org/a11y/atspi/registry`. `methodCall` returns errors as values. |
| 6 | Models the a11y address lookup | FAIL | goose has no `org.a11y.Bus.GetAddress` step and no `initFromAddress`. The port owns all five steps of section 6. |
| 7 | fd and event loop | PASS, after a four-line change | One event loop. goose runs in a zio task on a zio-backed `std.Io`. The port pumps `dispatch()`. Every D-Bus call blocks its executor. |

### 8.1 Work goose needs from this project

1. Clear `O_NONBLOCK` after `connect`, as in section 7.4. Without it, any
   `std.Io` that opens non-blocking sockets breaks the handshake.
2. Ask the session bus for the a11y address, or accept `AT_SPI_BUS_ADDRESS`
   only. The current fallback at `connection.zig:497-500` names a socket that
   does not exist on a systemd `at-spi-bus-launcher` host.
3. Do not fold `EAGAIN` into `error.ReadFailed` at `connection.zig:189-190`.
   Return a distinct error so the caller can await readiness.
4. Add an asynchronous method call, or document that every call blocks the
   calling thread. Section 7.6 condition 3 turns on this.
5. Widen `SocketIterator` at `connection.zig:1451-1475`. It parses
   `unix:path=` only. `grep -rn "abstract\|tmpdir\|tcp:"` over `goose/src`
   returns no match. `[INFERENCE]` A distro that hands out an abstract socket
   would break the port. That case was not observable on this host.
6. Upstream in zio: re-export `fromRuntime` and `toRuntime` from `zio.zig`, as
   in section 7.2. Three lines, no behaviour change.

### 8.2 Judgement on adopting goose v3.3.0

Adopt it for the AT-SPI adapter. Do not write a D-Bus client instead.

The reasons are all in the evidence above. goose already does the parts that
take longest to get right: SASL `EXTERNAL`, header field parsing, alignment and
endianness, fd passing over `SCM_RIGHTS`, match rules, signal dispatch, and the
introspection XML reader. Section 5 shows it reading a live registry. Section 4
shows it taking a live signal off the a11y bus and decoding the body.

The defects found are small and local. Two are four lines each, in files the
port already knows it will read. Both are visible in the source without a
runtime, so the port can carry them as a pinned fork with a written reason.

The port still writes these parts itself:

- The five steps of the two-step bus lookup, from section 6.
- The AT-SPI interfaces as proxies over `goose.proxy`, from the XML.
- A synthetic AT-SPI peer for tests, because nothing is on this bus.
- The zio pump loop around `getFd` and `dispatch`.
- A rule for where D-Bus calls run, because they block.

That is the same work the port would do on top of any D-Bus client, minus the
wire format.

One risk stays open. goose v3.3.0 predates this design and its author may not
accept the `O_NONBLOCK` change. The fallback is a pinned fork, and the project
already pins packages by commit elsewhere. `[INFERENCE]` A fork costs one
dependency to maintain. Writing a second D-Bus client costs the wire format.

