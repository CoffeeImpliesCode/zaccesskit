# 41 — AT-SPI adapter build map

## 0. Scope, sources, and how to read this

This document is the working map for the AT-SPI adapter. An implementer
starts here and writes `src/adapters/atspi/` from it.

| Item | Value |
|---|---|
| Port | `zaccesskit`, a pure Zig port of the Rust `accesskit` crate |
| Upstream crates | `accesskit_unix` 0.24.0 and `accesskit_atspi_common` 0.21.0 |
| Upstream tree | `/tmp/scratch/accesskit` at `466e24e252103f4d82bd6fbab98141b551e46e0c` |
| goose | `v3.3.0`, commit `8c6ee3a`, at `/tmp/scratch/goose` |
| zio | 0.18.0, at `~/zio`, pinned `2662fdc45997611b962b560c513c16963475a01b` |
| Zig | 0.16.0 |
| Live bus | `unix:path=/run/user/33156/at-spi/bus` |

Citations use two prefixes. `UP/` means
`/tmp/scratch/accesskit/`. `GO/` means
`/tmp/scratch/goose/src/`. `ZIO/` means
`~/zio/src/`.

Every claim about upstream carries an `UP/` line number read at that commit.
Every claim about goose carries a `GO/` line number read at that tag. Anything
marked `[INFERENCE]` is not established by a source reading.

**What this document owns.** The D-Bus surface (§1), the module split (§2), the
goose integration (§3), the `O_NONBLOCK` fix (§4), the runtime (§5), the
verification an implementer can run today (§6), and the upstream items with no
counterpart (§7).

**What this document does not own.** The module layout is fixed by
`docs/30-port-design.md` section 3.3. The C ABI belongs to
`docs/31-c-abi-design.md`. The milestone order belongs to `docs/40-plan.md`.
Where this document and `docs/30` disagree, `docs/30` wins and this document is
wrong.

### 0.1 Size of the port surface

| Upstream file group | Lines |
|---|---:|
| `UP/adapters/atspi-common/src/*.rs`, 13 files | 4417 |
| `UP/adapters/unix/src/*.rs`, 5 files | 809 |
| `UP/adapters/unix/src/atspi/*.rs`, 4 files | 662 |
| `UP/adapters/unix/src/atspi/interfaces/*.rs`, 13 files | 1289 |
| **Total** | **7177** |

`wc -l` over each group produced these numbers on this host. See §8 for the
correction to `docs/13`.

---

## 1. The D-Bus surface, verified against the source

`docs/13-atspi-protocol.md` section 3 holds a 95-row table. Every row was
checked against the pinned upstream tree. §1.10 lists what the source
contradicts.

Direction in this section:

- **in** means the peer calls it and the adapter answers.
- **out** means the adapter calls it.
- **both** means either side may use it.

### 1.1 Object paths

| Path | Interface on it | Direction | Source |
|---|---|---|---|
| `/org/a11y/bus` | `org.a11y.Bus`, `org.a11y.Status` | out | `UP/adapters/unix/src/atspi/bus.rs:45`, `UP/adapters/unix/src/context.rs:184` |
| `/org/a11y/atspi/accessible/root` on `org.a11y.atspi.Registry` | `org.a11y.atspi.Socket` | out | `UP/adapters/unix/src/atspi/bus.rs:87-88` |
| `/org/a11y/atspi/accessible/root` | `org.a11y.atspi.Application`, `org.a11y.atspi.Accessible` | in | `UP/adapters/unix/src/atspi/object_id.rs:15`, registered at `bus.rs:83` and `bus.rs:94-102` |
| `/org/a11y/atspi/accessible/{adapter}/{node}` | the ten node interfaces | in | `UP/adapters/unix/src/atspi/object_id.rs:36-41` |
| `/org/a11y/atspi/cache` | `org.a11y.atspi.Cache` | in and out | `UP/adapters/unix/src/atspi/object_id.rs:16`, `object_id.rs:18-20` |
| `/org/a11y/atspi/null` | none. It is the absent-child marker | out | `UP/adapters/unix/src/atspi/object_address.rs:14`, `:30-36` |
| `/org/a11y/atspi/registry` on `org.a11y.atspi.Registry` | `org.a11y.atspi.Registry` | out, in tests only | not an upstream path. `docs/26` section 5 measured it on the live bus |

Two shapes matter. `{adapter}` is the `usize` from `next_adapter_id`
(`UP/adapters/atspi-common/src/adapter.rs:356-358`). `{node}` is the decimal
`u128` of a `FullNodeId` (`object_id.rs:40`). Two windows therefore never share
a path.

### 1.2 Outbound calls the adapter makes

| Interface | Member | Direction | In | Out | Source | Note |
|---|---|---|---|---|---|---|
| `org.a11y.Bus` | `GetAddress` | out | none | `s` | `bus.rs:45` | Only when `AT_SPI_BUS_ADDRESS` is unset |
| `org.a11y.Status` | `PropertiesChanged` on `IsEnabled` | in | `s a{sv} as` | none | `context.rs:184-185` | The one signal the adapter subscribes to |
| `org.freedesktop.DBus` | `Hello` | out | none | `s` | not in the upstream source | goose sends it. See §3.3 |
| `org.freedesktop.DBus` | `Introspect` | out, tests only | none | `s` | not in the upstream source | Used by §6 |
| `org.a11y.atspi.Socket` | `Embed` | out | `(so)` | `(so)` | `bus.rs:86-89` | The plug must be the caller's own unique name |
| `org.freedesktop.DBus.Properties` | `Set` on `Application.Id` | in | `ssv` | none | `interfaces/application.rs:35-38` | The registry writes the id. See §1.6 |

AccessKit makes no other client call. The whole adapter has one `use atspi`
statement, at `UP/adapters/unix/src/atspi/bus.rs:15-19`, and its `proxy` line at
`bus.rs:18` names exactly two proxies, `bus::BusProxy` and
`socket::SocketProxy`. Each is called once.

### 1.3 `org.a11y.atspi.Application` on the root path

Declared at `UP/adapters/unix/src/atspi/interfaces/application.rs:13`.

| Wire name | Kind | Type | Direction | Source | Value |
|---|---|---|---|---|---|
| `ToolkitName` | property read | `s` | in | `application.rs:15-18` | `AppContext.toolkit_name`, or the process file name (`context.rs:36-41`) |
| `Version` | property read | `s` | in | `application.rs:20-23` | `AppContext.toolkit_version`, `""` when absent |
| `AtspiVersion` | property read | `s` | in | `application.rs:25-28` | The literal `"2.1"` |
| `Id` | property read | `i` | in | `application.rs:30-33` | `AppContext.id`, `-1` before the registry sets it |
| `Id` | property write | `i` | in | `application.rs:35-38` | Stores the registry-assigned id |

The AT-SPI reference names this property `ToolkitVersion`. AccessKit names it
`Version`. Reproduce `Version`. See §1.10, row K1.

### 1.4 `org.a11y.atspi.Accessible` on a node path and on the root path

Declared twice. The node block is at
`UP/adapters/unix/src/atspi/interfaces/accessible.rs:33`. The root block is at
`accessible.rs:166`. Both carry the interface name `org.a11y.atspi.Accessible`.
Every member is inbound.

| Wire name | Kind | Type | Node source | Root source | Root has it |
|---|---|---|---|---|---|
| `Name` | property read | `s` | `accessible.rs:35-38` | `accessible.rs:168-171` | yes |
| `Description` | property read | `s` | `accessible.rs:40-43` | `accessible.rs:173-176` | yes |
| `Parent` | property read | `(so)` | `accessible.rs:45-57` | `accessible.rs:178-186` | yes |
| `ChildCount` | property read | `i` | `accessible.rs:59-62` | `accessible.rs:188-191` | yes |
| `Locale` | property read | `s` | `accessible.rs:64-67` | `accessible.rs:193-196` | yes |
| `AccessibleId` | property read | `s` | `accessible.rs:69-72` | `accessible.rs:198-201` | yes |
| `GetChildAtIndex` | method | `i` to `(so)` | `accessible.rs:74-87` | `accessible.rs:203-213` | yes |
| `GetChildren` | method | none to `a(so)` | `accessible.rs:89-99` | `accessible.rs:215-221` | yes |
| `GetIndexInParent` | method | none to `i` | `accessible.rs:101-103` | `accessible.rs:223-225` | yes |
| `GetRelationSet` | method | none to `a(ua(so))` | `accessible.rs:105-119` | `accessible.rs:227-229` | yes |
| `GetRole` | method | none to `u` | `accessible.rs:121-123` | `accessible.rs:231-233` | yes |
| `GetLocalizedRoleName` | method | none to `s` | `accessible.rs:125-127` | none | **no** |
| `GetState` | method | none to `au` | `accessible.rs:129-131` | `accessible.rs:235-237` | yes |
| `GetAttributes` | method | none to `a{ss}` | `accessible.rs:133-135` | none | **no** |
| `GetApplication` | method | none to `(so)` | `accessible.rs:137-139` | `accessible.rs:239-241` | yes |
| `GetInterfaces` | method | none to `as` | `accessible.rs:141-143` | `accessible.rs:243-245` | yes |

The root object exports 14 of the 16 members. The asymmetry is real and the port
must reproduce it. The root's `GetRelationSet` always returns an empty vector
(`accessible.rs:227-229`), its `GetRole` always returns
`AtspiRole::Application` (`accessible.rs:231-233` and
`UP/adapters/atspi-common/src/node.rs:1846-1848`), and its `GetState` always
returns an empty set (`accessible.rs:235-237` and `node.rs:1854-1856`).

`GetChildAtIndex` returns `/org/a11y/atspi/null` for an absent child
(`interfaces/mod.rs:26-32`). A negative index returns
`org.freedesktop.DBus.Error.InvalidArgs` with the text
`Index can't be negative.` (`accessible.rs:76-77` and `accessible.rs:205-206`).

### 1.5 The nine node interfaces

A node exports a variable subset. `NodeWrapper.interfaces` at
`UP/adapters/atspi-common/src/node.rs:484-514` computes the set, and
`bus.rs:120-181` registers one interface per set member. The ten checks are at
`bus.rs:127`, `:134`, `:138`, `:145`, `:149`, `:153`, `:160`, `:164`, `:171`,
`:175`.

| Interface | Condition on the node | Condition source |
|---|---|---|
| `org.a11y.atspi.Accessible` | always | `node.rs:485` |
| `org.a11y.atspi.Action` | `is_clickable(filter)` | `node.rs:445-447` |
| `org.a11y.atspi.Component` | `raw_bounds().is_some()` or the node is the tree root | `node.rs:449-451` |
| `org.a11y.atspi.Document` | role is `RootWebArea` or `PdfRoot` | `node.rs:453-455` |
| `org.a11y.atspi.EditableText` | `is_text_input()` and `supports_text_ranges()` | `node.rs:457-459` |
| `org.a11y.atspi.Hyperlink` | `supports_url()` | `node.rs:461-463` |
| `org.a11y.atspi.Image` | role is `Canvas`, `DocCover`, `GraphicsSymbol`, `Image` or `SvgRoot` | `node.rs:465-470` |
| `org.a11y.atspi.Selection` | `is_container_with_selectable_children()` | `node.rs:472-474` |
| `org.a11y.atspi.Text` | `supports_text_ranges()` | `node.rs:476-478` |
| `org.a11y.atspi.Value` | `current_value().is_some()` | `node.rs:480-482` |

Every member below is inbound.

#### `org.a11y.atspi.Action`, declared at `interfaces/action.rs:21`

| Wire name | Kind | Type | Source | Value |
|---|---|---|---|---|
| `NActions` | property read | `i` | `action.rs:23-26` | `1` when clickable, else `0` (`node.rs:525-527`) |
| `GetDescription` | method | `i` to `s` | `action.rs:28-30` | Always `""` |
| `GetName` | method | `i` to `s` | `action.rs:32-34` | `"click"` at index 0, else `""` (`node.rs:529-538`) |
| `GetLocalizedName` | method | `i` to `s` | `action.rs:36-38` | The same string as `GetName` |
| `GetKeyBinding` | method | `i` to `s` | `action.rs:40-42` | Always `""` |
| `GetActions` | method | none to `a(sss)` | `action.rs:44-46` | Name, description, key binding triples |
| `DoAction` | method | `i` to `b` | `action.rs:48-50` | `true` at index 0, `false` otherwise (`node.rs:1120-1131`) |

#### `org.a11y.atspi.Component`, declared at `interfaces/component.rs:27`

| Wire name | Kind | Type | Source | Value |
|---|---|---|---|---|
| `Contains` | method | `i i u` to `b` | `component.rs:29-33` | `node.rs:1133-1143` |
| `GetAccessibleAtPoint` | method | `i i u` to `(so)` | `component.rs:35-50` | `node.rs:1145-1161` |
| `GetExtents` | method | `u` to `(iiii)` | `component.rs:52-57` | `node.rs:1163-1171` |
| `GetLayer` | method | none to `u` | `component.rs:59-61` | `Layer::Window` for role `Window`, else `Layer::Widget` (`node.rs:1173-1182`) |
| `GrabFocus` | method | none to `b` | `component.rs:63-65` | `Action::Focus` (`node.rs:1184-1192`) |
| `ScrollTo` | method | `u` to `b` | `component.rs:67-69` | `Action::ScrollIntoView` (`node.rs:1194-1203`) |
| `ScrollToPoint` | method | `u i i` to `b` | `component.rs:71-75` | `node.rs:1204-1223` |

#### `org.a11y.atspi.Document`, declared at `interfaces/document.rs:27`

| Wire name | Kind | Type | Source | Value |
|---|---|---|---|---|
| `CurrentPageNumber` | property read | `i` | `document.rs:29-32` | Always `NotSupported` |
| `PageCount` | property read | `i` | `document.rs:34-37` | Always `NotSupported` |
| `GetAttributeValue` | method | `s` to `s` | `document.rs:39-43` | One attribute, matched case-insensitively (`node.rs:582-587`) |
| `GetAttributes` | method | none to `a{ss}` | `document.rs:45-47` | `node.rs:570-580` |
| `GetLocale` | method | none to `s` | `document.rs:49-51` | Always `NotSupported` |
| `GetTextSelections` | method | none to `a((so)i(so)ib)` | `document.rs:53-55` | Always `NotSupported` |
| `SetTextSelections` | method | `a((so)i(so)ib)` to `b` | `document.rs:57-59` | Always `NotSupported` |

The `NotSupported` message text is `document operation is not supported`
(`document.rs:10-12`).

#### `org.a11y.atspi.EditableText`, declared at `interfaces/editable_text.rs:25`

| Wire name | Kind | Type | Source | Value |
|---|---|---|---|---|
| `SetTextContents` | method | `s` to `b` | `editable_text.rs:27-31` | `false` when the node is read-only (`node.rs:1225-1240`) |
| `InsertText` | method | `i s i` to `b` | `editable_text.rs:33-35` | Always `NotSupported` |
| `CopyText` | method | `i i` to none | `editable_text.rs:37-39` | Always `NotSupported` |
| `CutText` | method | `i i` to `b` | `editable_text.rs:41-43` | Always `NotSupported` |
| `DeleteText` | method | `i i` to `b` | `editable_text.rs:45-47` | Always `NotSupported` |
| `PasteText` | method | `i` to `b` | `editable_text.rs:49-51` | Always `NotSupported` |

#### `org.a11y.atspi.Hyperlink`, declared at `interfaces/hyperlink.rs:26`

| Wire name | Kind | Type | Source | Value |
|---|---|---|---|---|
| `NAnchors` | property read | `i` | `hyperlink.rs:28-31` | `1` when the node has a URL, else `0` (`node.rs:1242-1244`) |
| `StartIndex` | property read | `i` | `hyperlink.rs:33-36` | Always `-1` (`node.rs:1246-1251`) |
| `EndIndex` | property read | `i` | `hyperlink.rs:38-41` | Always `-1` (`node.rs:1253-1258`) |
| `GetObject` | method | `i` to `(so)` | `hyperlink.rs:43-53` | The node itself at index 0 (`node.rs:1260-1268`) |
| `GetURI` | method | `i` to `s` | `hyperlink.rs:55-58` | The name is overridden by `#[zbus(name = "GetURI")]` at `hyperlink.rs:55` |
| `IsValid` | method | none to `b` | `hyperlink.rs:60-62` | `node.rs:1280-1282` |

#### `org.a11y.atspi.Image`, declared at `interfaces/image.rs:22`

| Wire name | Kind | Type | Source | Value |
|---|---|---|---|---|
| `ImageDescription` | property read | `s` | `image.rs:24-27` | The node description (`node.rs:1284-1286`) |
| `ImageLocale` | property read | `s` | `image.rs:29-34` | Always `NotSupported`, text `image locale is not supported` |
| `GetImageExtents` | method | `u` to `(iiii)` | `image.rs:36-41` | `node.rs:1288-1290` |
| `GetImagePosition` | method | `u` to `(ii)` | `image.rs:43-45` | `node.rs:1292-1295` |
| `GetImageSize` | method | none to `(ii)` | `image.rs:47-49` | `node.rs:1297-1300` |

#### `org.a11y.atspi.Selection`, declared at `interfaces/selection.rs:26`

| Wire name | Kind | Type | Source | Value |
|---|---|---|---|---|
| `NSelectedChildren` | property read | `i` | `selection.rs:28-31` | `node.rs:1302-1310` |
| `GetSelectedChild` | method | `i` to `(so)` | `selection.rs:33-43` | `node.rs:1312-1320` |
| `SelectChild` | method | `i` to `b` | `selection.rs:45-49` | `node.rs:1322-1344` |
| `DeselectSelectedChild` | method | `i` to `b` | `selection.rs:51-55` | `node.rs:1346-1370` |
| `IsChildSelected` | method | `i` to `b` | `selection.rs:57-61` | `node.rs:1372-1379` |
| `SelectAll` | method | none to `b` | `selection.rs:63-65` | Always `false` (`node.rs:1381-1384`) |
| `ClearSelection` | method | none to `b` | `selection.rs:67-69` | Always `false` (`node.rs:1386-1389`) |
| `DeselectChild` | method | `i` to `b` | `selection.rs:71-75` | `node.rs:1391-1413` |

Every index-taking member runs `map_child_index` at `selection.rs:78-82`, which
maps a negative `i32` to `InvalidArgs` with the text
`Index can't be negative.`

#### `org.a11y.atspi.Text`, declared at `interfaces/text.rs:25`

| Wire name | Kind | Type | Source | Value |
|---|---|---|---|---|
| `CharacterCount` | property read | `i` | `text.rs:27-30` | `node.rs:1415-1423` |
| `CaretOffset` | property read | `i` | `text.rs:32-35` | `node.rs:1425-1434` |
| `GetStringAtOffset` | method | `i u` to `(sii)` | `text.rs:37-45` | `node.rs:1436-1457` |
| `GetText` | method | `i i` to `s` | `text.rs:47-51` | `node.rs:1459-1465` |
| `SetCaretOffset` | method | `i` to `b` | `text.rs:53-55` | `node.rs:1467-1482` |
| `GetAttributeValue` | method | `i s` to `s` | `text.rs:57-61` | `node.rs:1484-1492` |
| `GetAttributes` | method | `i` to `(a{ss}ii)` | `text.rs:63-68` | `node.rs:1494-1499` |
| `GetDefaultAttributes` | method | none to `a{ss}` | `text.rs:70-74` | `node.rs:1501-1511` |
| `GetCharacterExtents` | method | `i u` to `(iiii)` | `text.rs:76-80` | `node.rs:1513-1528` |
| `GetOffsetAtPoint` | method | `i i u` to `i` | `text.rs:82-86` | `node.rs:1530-1544` |
| `GetNSelections` | method | none to `i` | `text.rs:88-90` | `node.rs:1546-1553` |
| `GetSelection` | method | `i` to `(ii)` | `text.rs:92-94` | `node.rs:1555-1578` |
| `AddSelection` | method | `i i` to `b` | `text.rs:96-100` | A redirect to `SetSelection(0, ...)` at `node.rs:1580-1583` |
| `RemoveSelection` | method | `i` to `b` | `text.rs:102-106` | `node.rs:1585-1608` |
| `SetSelection` | method | `i i i` to `b` | `text.rs:108-117` | `node.rs:1610-1633` |
| `GetRangeExtents` | method | `i i u` to `(iiii)` | `text.rs:119-128` | `node.rs:1635-1654` |
| `GetAttributeRun` | method | `i b` to `(a{ss}ii)` | `text.rs:130-138` | `node.rs:1656-1693` |
| `ScrollSubstringTo` | method | `i i u` to `b` | `text.rs:140-149` | `node.rs:1695-1726` |
| `ScrollSubstringToPoint` | method | `i i u i i` to `b` | `text.rs:151-163` | `node.rs:1728-1758` |

`AddSelection` must stay a redirect. Porting it as a second body would
duplicate the logic and break the single-selection invariant at
`node.rs:1581-1582`.

#### `org.a11y.atspi.Value`, declared at `interfaces/value.rs:23`

| Wire name | Kind | Type | Source | Value |
|---|---|---|---|---|
| `MinimumValue` | property read | `d` | `value.rs:25-28` | `min_numeric_value` or `f64::MIN` (`node.rs:1760-1762`) |
| `MaximumValue` | property read | `d` | `value.rs:30-33` | `max_numeric_value` or `f64::MAX` (`node.rs:1764-1766`) |
| `MinimumIncrement` | property read | `d` | `value.rs:35-38` | `numeric_value_step` or `0.0` (`node.rs:1768-1770`) |
| `CurrentValue` | property read | `d` | `value.rs:40-43` | `node.rs:1772-1777` |
| `CurrentValue` | property write | `d` | `value.rs:45-48` | `Action::SetValue` (`node.rs:1779-1788`) |

### 1.6 `org.a11y.atspi.Cache` on the cache path

Declared at `interfaces/cache.rs:108`.

| Wire name | Kind | Type | Direction | Source |
|---|---|---|---|---|
| `GetItems` | method | none to `a((so)(so)(so)iiassusau)` | in | `cache.rs:110-112` |
| `AddAccessible` | signal | `((so)(so)(so)iiassusau)` | out | `bus.rs:441-446` |
| `RemoveAccessible` | signal | `(so)` | out | `bus.rs:448-461` |

The item field order is fixed by the AT-SPI2 reference XML and confirmed here:
`object`, `app`, `parent`, `index`, `children`, `ifaces`, `short_name`, `role`,
`name`, `states`. The builder at `cache.rs:31-58` fills `short_name` from
`node.name` and `name` from `node.description`. That inversion is deliberate and
easy to get wrong.

`GetItems` returns the application item first, then every descendant
(`cache.rs:94-105`). The application item's `parent` is the desktop reference
that `Embed` returned, or the default when `Embed` has not answered
(`cache.rs:63-73`).

The reference XML also declares a `Ready` signal and a `version` property on
`org.a11y.atspi.Cache`. AccessKit exports neither. See §1.10, row K6.

### 1.7 Signals the adapter emits

All of them are broadcast. Every emission passes
`Option::<BusName>::None` as the destination, at `bus.rs:470` for cache
signals and `bus.rs:492` for event signals.

#### The event body

Every event signal, on `Event.Object`, `Event.Window` and `Event.Document`,
carries the same five arguments.

| Field | Type | Default when unset |
|---|---|---|
| `kind` | `s` | `""` |
| `detail1` | `i` | `0` |
| `detail2` | `i` | `0` |
| `any_data` | `v` | a `u32` zero |
| `properties` | `a{sv}` | empty |

The wire signature is `siiva{sv}`. All 57 signals in the seven
`org.a11y.atspi.Event.*` interfaces of the AT-SPI2 reference XML declare exactly
those five arguments, in that order. See §1.10, row K2 for the census.

`docs/13` records the signature correctly and describes the field `properties`
as skipped on the wire. `docs/26` section 4 recorded `siivso` and was wrong.
That line was corrected on 2026-10-05, when `docs/26` was re-read against the
same XML and the signature set to `siiva{sv}` with the five arguments named.

`[INFERENCE]` AccessKit emits `properties` as an empty dictionary. The port must
prove this against a live AT-SPI client before it ships, because a body with
four arguments is a body every client fails to decode.

#### `org.a11y.atspi.Event.Object`, interface string at `bus.rs:269`

| Member | `kind` | `detail1` | `detail2` | `any_data` | Source |
|---|---|---|---|---|---|
| `ActiveDescendantChanged` | `""` | 0 | 0 | `(so)` | `bus.rs:283-291` |
| `Announcement` | `""` | politeness | 0 | `s` | `bus.rs:292-297` |
| `BoundsChanged` | `""` | 0 | 0 | `(iiii)` | `bus.rs:298-302` |
| `ChildrenChanged` on add | `"add"` | index | 0 | `(so)` | `bus.rs:308-318` |
| `ChildrenChanged` on remove | `"remove"` | `-1` | 0 | `(so)` | `bus.rs:319-329` |
| `PropertyChange` on name | `"accessible-name"` | 0 | 0 | `s` | `bus.rs:332-341` |
| `PropertyChange` on description | `"accessible-description"` | 0 | 0 | `s` | `bus.rs:333-342` |
| `PropertyChange` on parent | `"accessible-parent"` | 0 | 0 | `(so)` | `bus.rs:334-351` |
| `PropertyChange` on role | `"accessible-role"` | 0 | 0 | `u` | `bus.rs:335-352` |
| `PropertyChange` on value | `"accessible-value"` | 0 | 0 | `d` | `bus.rs:337-353` |
| `SelectionChanged` | `""` | 0 | 0 | `u32` zero | `bus.rs:357-360` |
| `StateChanged` | `state.to_static_str()` | `1` or `0` | 0 | `u32` zero | `bus.rs:361-366` |
| `TextCaretMoved` | `""` | offset | 0 | `u32` zero | `bus.rs:303-307` |
| `TextChanged` on insert | `"insert"` | start index | length | `s` | `bus.rs:367-378` |
| `TextChanged` on delete | `"delete"` | start index | length | `s` | `bus.rs:379-390` |
| `TextSelectionChanged` | `""` | 0 | 0 | `u32` zero | `bus.rs:391-394` |

Two names differ from the Rust variant name. `ObjectEvent::CaretMoved` goes on
the wire as `TextCaretMoved`, at `bus.rs:274`. `ObjectEvent::PropertyChanged`
goes on the wire as `PropertyChange`, at `bus.rs:276`. The member name is
chosen at run time by the match at `bus.rs:270-281`, not by a macro.

#### `org.a11y.atspi.Event.Window`, interface string at `bus.rs:415`

| Member | `kind` | `any_data` | Source |
|---|---|---|---|
| `Activate` | `""` | the window name as `s` | `bus.rs:398-417`, name at `:414` |
| `Deactivate` | `""` | the window name as `s` | `bus.rs:398-417`, name at `:414` |

#### `org.a11y.atspi.Event.Document`, interface string at `bus.rs:434`

| Member | `kind` | Source |
|---|---|---|
| `LoadComplete` | `""` | `bus.rs:419-439`, fired at `UP/adapters/atspi-common/src/node.rs:686-690` |

### 1.8 Signals the adapter subscribes to

One, and it is on the session bus.

| Interface | Member | Where | What it drives |
|---|---|---|---|
| `org.a11y.Status` | `IsEnabled` through `PropertiesChanged` | `UP/adapters/unix/src/context.rs:184-185` | `Bus::new` on `true`, drop the bus on `false` (`context.rs:142-155`) |

The reference XML also declares `ScreenReaderEnabled` on `org.a11y.Status`.
AccessKit never reads it.

AccessKit never subscribes to anything on the accessibility bus. `grep -rn
"add_match\|AddMatch" UP/adapters/unix/src` returns nothing. The launcher
policy allows every broadcast through, so a match rule is not needed. See §1.9,
row K5.

### 1.9 Error names the adapter must produce

`map_error` at `UP/adapters/unix/src/util.rs:26-38` is the only mapping.

| Internal error | D-Bus error name | Message | Source |
|---|---|---|---|
| `Defunct` | `org.freedesktop.DBus.Error.UnknownObject` | the object path | `util.rs:28-30` |
| `UnsupportedInterface` | `org.freedesktop.DBus.Error.UnknownObject` | the object path | `util.rs:28-30` |
| `TooManyChildren` | `org.freedesktop.DBus.Error.Failed` | `Too many children.` | `util.rs:31` |
| `IndexOutOfRange` | `org.freedesktop.DBus.Error.Failed` | `Index is too big.` | `util.rs:32` |
| `TooManyCharacters` | `org.freedesktop.DBus.Error.Failed` | `Too many characters.` | `util.rs:33` |
| `UnsupportedTextGranularity` | `org.freedesktop.DBus.Error.Failed` | `Unsupported text granularity.` | `util.rs:34-36` |
| a negative index | `org.freedesktop.DBus.Error.InvalidArgs` | `Index can't be negative.` | `accessible.rs:76-77`, `selection.rs:78-82` |
| an unimplemented member | `org.freedesktop.DBus.Error.NotSupported` | the member-specific text | `document.rs:10-12`, `editable_text.rs:10-12`, `image.rs:31-33` |

Five distinct names reach the wire. goose sends one. See §3, gap G6.

### 1.10 What the source contradicts

`docs/13` section 3 is correct on the member names, the paths, the directions,
the interface conditions, and the `Event.Window` and `Event.Document` mappings.
The following rows are wrong or unverifiable.

| Id | `docs/13` says | The source says | Where |
|---|---|---|---|
| K1 | `Application.Version` is correct, and §3.14 lists `Application.ToolkitVersion` as not exported. Both are right, but the name needs spelling out | The reference XML calls the property `ToolkitVersion`; AccessKit exports `Version`. A port that follows the XML names the wrong property | `UP/adapters/unix/src/atspi/interfaces/application.rs:20` |
| K2 | The event body signature is `siiva{sv}`, and `properties` is "skipped on the wire" | The signature is right. `docs/26` section 4 recorded `siivso` and was corrected on 2026-10-05 against the same XML. The "skipped on the wire" half is wrong, because the XML gives every event signal five arguments. See the census below | `UP/adapters/unix/src/atspi/bus.rs:282-395`, XML `Event.xml` |
| K3 | `Hyperlink.NAnchors` has type `n`, that is `i16` | The return type is `fdo::Result<i32>` and the provider is `pub fn n_anchors(&self) -> Result<i32>`. The wire type is `i` | `interfaces/hyperlink.rs:29`, `UP/adapters/atspi-common/src/node.rs:1242` |
| K4 | `Selection.ClearSelection` "Clear the whole selection" | It returns `Ok(false)` and never clears. The comment reads "We don't support deselecting all children at once" | `UP/adapters/atspi-common/src/node.rs:1386-1389` |
| K5 | "`Socket.Embedded` and `Socket.Unembed` exist in `xml/Socket.xml` but AccessKit never subscribes to them" | Both are methods, not signals. The socket calls them on the plug, so the plug would have to export them. The conclusion holds, the wording does not | XML `Socket.xml`, `UP/adapters/unix/src/atspi/interfaces/` has no `Socket` module |
| K6 | §4.4 lists only `AddAccessible` and `RemoveAccessible` on `org.a11y.atspi.Cache` | The reference XML also declares a `Ready` signal, added in Cache version 2, and a `version` property. AccessKit exports neither. A client that waits for `Ready` before `GetItems` waits forever against this adapter | XML `Cache.xml`, `interfaces/cache.rs:108-113` |
| K7 | "`wc -l` over `adapters/atspi-common/src/*.rs` gives 5226 lines in total" | It gives 4417. The 5226 figure is 4417 plus the 809 lines of `adapters/unix/src/*.rs`, that is, the next crate | `UP/adapters/atspi-common/src/`, `UP/adapters/unix/src/` |
| K8 | §7.6 says `add_node` "registers at `:57` and emits the cache event at `:58`" | `add_node` starts at line 49, registers at 60, and emits at 61 | `UP/adapters/atspi-common/src/adapter.rs:49`, `:60`, `:61` |
| K9 | §2 says `register_root_node` is at `bus.rs:73` | It is at `bus.rs:76` | `UP/adapters/unix/src/atspi/bus.rs:76` |
| K10 | §6.1 says goose "binds `Signal` fields" at compile time | `Signal(T)` has `name`, `interface` and `path` as ordinary mutable fields. The port sets all three at run time. See §3 | `GO/dbus_types.zig:8-27` |
| K11 | §6.4 marks the `(sa{sv})` shape as `[INFERENCE]` | The reference XML settles it. `CacheItem` is `((so)(so)(so)iiassusau)` and there is no `a{sv}` around an object reference anywhere in the cache item. The variant only appears as the `any_data` of an event body | XML `Cache.xml` |

Three claims in `docs/13` could not be checked on this host, because the crate
they cite is a crates.io dependency and no registry cache exists here. Treat
each as unverified.

| Claim | Cited source | Why it is unverified |
|---|---|---|
| U1 | `EventBodyBorrowed` field names and defaults, `atspi-common-0.13.0/src/events/event_body.rs:188-210` | The crate is not on this host. The five-argument shape is established from the XML instead |
| U2 | `CacheItem` declaration order, `atspi-common-0.13.0/src/cache.rs:13-40` | The same. The order is established from the XML instead |
| U3 | `State::to_static_str`, `atspi-common-0.13.0/src/state.rs:231-282` | The same. The ten AT-SPI state strings are needed for `StateChanged` |

---

## 2. The module split

`docs/30-port-design.md` section 3.3 fixes the directory. This section fixes
the files inside it, the import graph, and who owns what.

### 2.1 The rule that decides ownership

Four rules, applied in this order.

1. A type belongs to the module whose data structure holds it. `docs/36-consumer-call-graph.md`
   section 1 states this for the consumer layer. It is the same rule here.
2. One module declares a type. A second copy of `NodeState` would make
   `NodeRef.state` point at a different type than `TreeState.nodes` holds.
3. Only `interfaces/root.zig` knows the complete interface list. Nothing else
   may name `org.a11y.atspi.Action`.
4. `objects.zig` owns the object register. No other module mutates it.

Zig permits an import cycle. An ownership question does not. Where two modules
would need each other, the shared declaration moves down.

### 2.2 The module list

Every upstream Rust file becomes one Zig file, per `AGENTS.md` section 6. Four
port-only modules replace the goose gaps, and five upstream files are deleted.

| Zig module | Upstream | Owns |
|---|---|---|
| `adapters/atspi/error.zig` | `atspi-common/src/error.rs`, `unix/src/util.rs:26-42` | the six-member `Error` set and its map to five D-Bus error names |
| `adapters/atspi/events.zig` | `atspi-common/src/events.rs` | `Event`, `ObjectEvent`, `WindowEvent`, `DocumentEvent`, `CacheEvent`, `Property` |
| `adapters/atspi/wire.zig` | port only | the ten wire enums, the member-name constants, the three path constants |
| `adapters/atspi/wire/rect.zig` | `atspi-common/src/rect.rs` | `Rect` and `Rect.invalid` |
| `adapters/atspi/wire/action.zig` | `atspi-common/src/action.rs` | `Action`, the `a(sss)` triple |
| `adapters/atspi/window_bounds.zig` | `atspi-common/src/util.rs:9-134` | `WindowBounds`, the four point and range conversions |
| `adapters/atspi/object_id.zig` | `unix/src/atspi/object_id.rs` | `ObjectId`, `ObjectId.path`, `ObjectId.toAddress`, `cachePath` |
| `adapters/atspi/object_address.zig` | `unix/src/atspi/object_address.rs` | `ObjectAddress`, the `(so)` struct, `ObjectAddress.null` |
| `adapters/atspi/text_attributes.zig` | `atspi-common/src/text_attributes.rs` | the ten text-attribute getters |
| `adapters/atspi/node.zig` | `atspi-common/src/node.rs`, split | `Node`, `Root`, `CacheNode`, `NodeIdOrRoot`, the about 70 accessors |
| `adapters/atspi/app_context.zig` | `atspi-common/src/context.rs` | `AppContext`, `Context`, the action-handler wrapper |
| `adapters/atspi/change_handler.zig` | `atspi-common/src/adapter.rs:30-278` | `ChangeHandler` and its four `TreeChangeHandler` slots |
| `adapters/atspi/platform_adapter.zig` | `atspi-common/src/adapter.rs:352-597` | `PlatformAdapter`, the tree it holds, `update`, `updateWindowFocusState` |
| `adapters/atspi/interfaces/accessible.zig` | `unix/src/atspi/interfaces/accessible.rs` | the node and root `Accessible` members |
| `adapters/atspi/interfaces/action.zig` | `unix/src/atspi/interfaces/action.rs` | the `Action` members |
| `adapters/atspi/interfaces/application.zig` | `unix/src/atspi/interfaces/application.rs` | the `Application` members |
| `adapters/atspi/interfaces/cache.zig` | `unix/src/atspi/interfaces/cache.rs` | the `Cache` member and the item builder |
| `adapters/atspi/interfaces/component.zig` | `unix/src/atspi/interfaces/component.rs` | the `Component` members |
| `adapters/atspi/interfaces/document.zig` | `unix/src/atspi/interfaces/document.rs` | the `Document` members |
| `adapters/atspi/interfaces/editable_text.zig` | `unix/src/atspi/interfaces/editable_text.rs` | the `EditableText` members |
| `adapters/atspi/interfaces/hyperlink.zig` | `unix/src/atspi/interfaces/hyperlink.rs` | the `Hyperlink` members |
| `adapters/atspi/interfaces/image.zig` | `unix/src/atspi/interfaces/image.rs` | the `Image` members |
| `adapters/atspi/interfaces/selection.zig` | `unix/src/atspi/interfaces/selection.rs` | the `Selection` members |
| `adapters/atspi/interfaces/text.zig` | `unix/src/atspi/interfaces/text.rs` | the `Text` members |
| `adapters/atspi/interfaces/value.zig` | `unix/src/atspi/interfaces/value.rs` | the `Value` members |
| `adapters/atspi/interfaces/root.zig` | `unix/src/atspi/interfaces/mod.rs` | the interface table, the introspection XML, `optionalObjectAddress` |
| `adapters/atspi/objects.zig` | port only | the path index, `registerInterface`, `unregisterInterface` |
| `adapters/atspi/dispatch.zig` | port only | `dispatch`: member name to handler, error name mapping |
| `adapters/atspi/message.zig` | `unix/src/adapter.rs:21-77`, `:246-276` | `Message`, the `AdapterCallback` slots as one struct |
| `adapters/atspi/adapter.zig` | `unix/src/adapter.rs:80-244` | `Adapter`, `AdapterState`, the three public entry points |
| `adapters/atspi/bus.zig` | `unix/src/atspi/bus.rs` | the two connections, `Embed`, `emitEvent`, `emitCacheSignal` |
| `adapters/atspi/pump.zig` | port only | the zio task that waits on the descriptor and calls `dispatch` |
| `adapters/atspi/runtime.zig` | port only, replaces `unix/src/executor.rs` | the `zio.Runtime` holder |
| `adapters/atspi/context.zig` | `unix/src/context.rs` | the select loop over the status stream and the message channel |
| `adapters/atspi/root.zig` | `unix/src/lib.rs` | the re-export barrel |

Five upstream files have no module.

| Upstream file | Lines | Why it is deleted |
|---|---:|---|
| `atspi-common/src/filters.rs` | 6 | One re-export of `accesskit_consumer::common_filter`. The port uses `consumer/filter.zig` directly |
| `atspi-common/src/callback.rs` | 15 | The `AdapterCallback` trait becomes `message.zig`. See `docs/12` section 8, row `docs/12:1064` |
| `atspi-common/src/simplified.rs` | 977 | Not compiled at this pin. See §7 |
| `unix/src/util.rs:11-24` | 14 | Two `block_on` definitions. zio has no blocking call in the port |
| `unix/src/mod.rs`, `unix/src/lib.rs` | 40 | Two barrels collapse into `root.zig` and `interfaces/root.zig` |

`node.zig` is 2065 upstream lines and exceeds the 250-line module budget. Split
it the way the function bodies cluster, not mechanically. The natural cuts are
the five groups in `UP/adapters/atspi-common/src/node.rs`: the role and state
mapping at `:87-443`, the interface set at `:445-514`, the change notifiers at
`:593-713`, the `PlatformNode` accessors at `:840-1788`, and the `PlatformRoot`
accessors at `:1809-2046`.

### 2.3 The import graph

The graph has no cycle. Arrows point from importer to imported.

```text
root.zig
  -> context.zig
  -> adapter.zig

context.zig
  -> adapter.zig -> platform_adapter.zig -> change_handler.zig
                                -> node.zig
                                -> app_context.zig
  -> message.zig -> events.zig, node.zig
  -> pump.zig -> bus.zig -> objects.zig -> interfaces/root.zig -> interfaces/*.zig
                        -> events.zig
  -> runtime.zig

adapter.zig
  -> platform_adapter.zig, message.zig, runtime.zig

platform_adapter.zig
  -> change_handler.zig -> node.zig, events.zig
  -> node.zig -> error.zig, events.zig, object_id.zig, window_bounds.zig,
                 text_attributes.zig, wire.zig, wire/rect.zig, wire/action.zig
  -> app_context.zig -> window_bounds.zig
  -> consumer/tree.zig, consumer/tree_state.zig, consumer/filter.zig

node.zig -> consumer/node_id.zig, consumer/tree_state.zig, consumer/node_ref/*.zig

interfaces/*.zig
  -> node.zig, object_id.zig, object_address.zig, error.zig, wire.zig,
     wire/rect.zig, wire/action.zig

object_id.zig -> (nothing)
object_address.zig -> (nothing)
error.zig -> wire.zig
events.zig -> error.zig, wire/rect.zig
window_bounds.zig -> consumer/geometry
wire.zig -> (nothing)
wire/rect.zig -> (nothing)
wire/action.zig -> (nothing)
```

Three edges carry the design.

| Edge | Why it exists and why only in this direction |
|---|---|
| `interfaces/root.zig -> interfaces/*.zig` | The table that names every interface lives in the barrel. An interface module must not import the barrel, or the barrel cannot import it |
| `objects.zig -> interfaces/root.zig` | The register needs the interface table to answer `Introspect` and to dispatch. The interface modules need nothing from the register, because each handler takes a `*Node` |
| `pump.zig -> bus.zig` and not the reverse | The bus owns the connection. The pump only watches the descriptor and calls `dispatch`. `bus.zig` must not know a pump exists |

The consumer and schema layers are imported, never the reverse. `docs/30`
section 6.3 rule A1 makes each adapter's import block checkable against two
allow lists.

### 2.4 The public surface of each module

| Module | Public surface |
|---|---|
| `error.zig` | `Error`, `mapError`, `mapErrorFromNode` |
| `events.zig` | `Event`, `ObjectEvent`, `WindowEvent`, `DocumentEvent`, `CacheEvent`, `Property` |
| `wire.zig` | the ten enums, `InterfaceSet`, `StateSet`, `Role`, `interfaceName` |
| `object_id.zig` | `ObjectId`, `ObjectId.path`, `ObjectId.toAddress`, `cachePath` |
| `object_address.zig` | `ObjectAddress`, `ObjectAddress.null`, `ObjectAddress.fromRef` |
| `node.zig` | `Node`, `Root`, `NodeIdOrRoot`, `CacheNode`, `Node.init`, about 70 accessors |
| `app_context.zig` | `AppContext`, `AppContext.init`, `Context`, `ActionHandlerNoMut` |
| `change_handler.zig` | `ChangeHandler.init`, the four `TreeChangeHandler` slots |
| `platform_adapter.zig` | `PlatformAdapter.init`, `update`, `updateWindowFocusState`, `setRootWindowBounds`, `platformNode`, `platformRoot`, `id` |
| `interfaces/root.zig` | `table`, `introspectionXml`, `optionalObjectAddress` |
| `interfaces/<name>.zig` | `descriptor`, `handle` |
| `objects.zig` | `ObjectRegister`, `init`, `deinit`, `register`, `unregister`, `lookup` |
| `dispatch.zig` | `dispatch`, `DispatchError` |
| `message.zig` | `Message`, `Message.send`, the three callback slots |
| `bus.zig` | `Bus`, `Bus.init`, `Bus.deinit`, `Bus.emitObjectEvent`, `Bus.emitWindowEvent`, `Bus.emitDocumentEvent`, `Bus.emitCacheAdd`, `Bus.emitCacheRemove` |
| `pump.zig` | `Pump`, `Pump.start`, `Pump.stop` |
| `runtime.zig` | `Runtime`, `Runtime.init`, `Runtime.deinit`, `Runtime.io`, `Runtime.spawnBlocking` |
| `adapter.zig` | `Adapter`, `Adapter.init`, `Adapter.deinit`, `setRootWindowBounds`, `updateIfActive`, `updateWindowFocusState` |
| `context.zig` | `EventLoop`, `EventLoop.start` |
| `root.zig` | `Adapter`, `Bus`, `Runtime`, the rest as re-exports |

Two naming rules from `AGENTS.md` apply to every row. A function is
`camelCase`. A function whose return type is a type is named in the type
namespace, so `ObjectId.path` and `ObjectId.toAddress` keep the type prefix and
`Root.id` is spelled `Root.id`.

---

## 3. The goose integration

`docs/26-goose-live-bus-probe.md` reached the verdict "adopt it for the AT-SPI
adapter". This section says exactly which goose symbols the adapter uses, and
which of the nine recorded gaps the adapter meets.

### 3.1 The nine gaps, and the verdict for this adapter

The nine gaps are the ones in `local://zaccesskit-risk-register.md` entries R1
and R8. R8's row G9 restates R1's row G1, so the register names ten ids for nine
distinct defects.

| Id | Gap | Recorded at | This adapter |
|---|---|---|---|
| G1 | no unregister for an exported object | `GO/connection.zig:740`, `:603-606` | **HIT** |
| G1b | `registered_interfaces` has no mutex | `GO/connection.zig:934-937` | **AVOIDED**, by construction |
| G2 | every incoming call scans the whole list | `GO/connection.zig:935-937` | **HIT** |
| G3 | `registerObject` always calls `requestName` | `GO/connection.zig:701` | **HIT** |
| G4 | `SocketIterator` parses only `unix:path=` | `GO/connection.zig:1458-1473` | **HIT off this host** |
| G5 | the member name is the Zig declaration name | `GO/dispatcher.zig:264` | **HIT** |
| G6 | every error becomes `DBus.Error.Failed` | `GO/dispatcher.zig:298` | **HIT** |
| G7 | no way to connect to an address learned at run time | `GO/connection.zig:1451`, `:474` | **HIT**, worked around with no patch |
| G8 | no first-class emit-signal call | recorded in R8 | **AVOIDED**, no patch |
| G9 | restatement of G1 | R8 | same as G1 |

The verdict per gap, with the reason.

| Id | Why |
|---|---|
| G1 | `UP/adapters/unix/src/atspi/bus.rs:194-243` removes ten interfaces for every node that leaves the tree, and `bus.rs:441-461` removes the cache entry with it. `registered_interfaces` is appended at `GO/connection.zig:740` and drained only inside `close` at `GO/connection.zig:603-606`. Object paths would leak for the life of the process |
| G1b | avoided by construction. `objects.zig` owns the register, and both the message drain and `dispatch` run on the pump task. One task, one register, no mutex. This must be stated in the module contract, because any second task that touches the register reintroduces the race |
| G2 | `dispatchUnsolicited` walks `self.registered_interfaces.items` comparing paths at `GO/connection.zig:935-937`. `Accessible.GetChildren` returns one path per child, and each is then looked up. Cost grows with tree size |
| G3 | `registerObject` calls `requestName` unconditionally at `GO/connection.zig:701`. AccessKit owns no well-known name. It is reached only through `Embed`, and the connection's unique name is the only identity it uses (`bus.rs:72-74`, `:88`) |
| G4 | the launcher emits `unix:abstract=` when the bind address fills `sun_path`, which `docs/13` section 2 records at `at-spi-bus-launcher.c:541`. `GO/connection.zig:1460` hard-codes `param = "path="`. This host serves `unix:path=`, so the test suite does not meet the defect, but a different host does. It is about 40 lines |
| G5 | `GO/dispatcher.zig:264` matches `std.mem.eql(u8, member, decl.name)`, and `GO/xml_generator.zig:59` writes the same string into the introspection XML. Every AT-SPI member name is UpperCamelCase, and `AGENTS.md` says functions are `camelCase`. One of the two rules must give. The port gives the Zig rule |
| G6 | `GO/dispatcher.zig:298` sends `org.freedesktop.DBus.Error.Failed` with `@errorName(err)` as the text. §1.9 needs five distinct names |
| G7 | `initWithBackend` at `GO/connection.zig:474` takes a `BusType`, and `SocketIterator` at `GO/connection.zig:1451` is private. The port does not patch goose. It resolves the address through `org.a11y.Bus.GetAddress`, puts the string into the `Environ.Map` under `AT_SPI_BUS_ADDRESS`, and lets `GO/connection.zig:494` read it. The fallback at `GO/connection.zig:498` names `bus_0` and is never used |
| G8 | `Signal(T)` at `GO/dbus_types.zig:8` declares `name`, `interface` and `path` as ordinary mutable fields at `GO/dbus_types.zig:10-12`. `trigger` at `GO/dbus_types.zig:24` reads them and builds the header. The port assigns all three at run time, so a runtime-computed member name costs about ten lines and no patch |

**A tenth defect, not in the register.** goose never learns its own unique name.
`sayHello` at `GO/connection.zig:549` sends `Hello`, takes the reply at
`GO/connection.zig:572`, and drops it at `GO/connection.zig:573`. There is no
`uniqueName` accessor and no field. A grep for `unique` over `GO/` returns two
doc comments and no declaration.

Upstream needs that name. `bus.rs:88` passes
`self.unique_name().as_str()` as the first half of the `Embed` plug, and the
AT-SPI reference XML states that the plug is "a string for the unique bus name
of the application". §6.4 measures what happens without it.

The fix is the same class as the `fcntl` fix in §4: keep the `Hello` reply,
store the `s` body, and expose a getter. It is about five lines at one known
location. `docs/30` section 7.3 already establishes a build-time patch step, so
this rides in the same patch with its own assertion.

### 3.2 The goose symbols the adapter uses

Every line number below was read at tag `v3.3.0`, commit `8c6ee3a`.

#### Connection, `GO/connection.zig`

| Symbol | Line | Use |
|---|---|---|
| `Connection` | 265 | the field type on `Bus` |
| `Backend` | 122 | the two values are `threaded` at 123 and `poll` at 124 |
| `BusType` | 128 | `Session` at 130, `System` at 132, `Accessibility` at 134 |
| `Connection.initWithBackend` | 474 | both connections, always with `.poll` |
| `Connection.init` | 469 | not used. It forces `.threaded` at 470 |
| `Connection.close` | 577 | adapter teardown |
| `Connection.getFd` | 292 | the descriptor the pump watches |
| `Connection.hasDataToRead` | 297 | the guard inside `dispatch`, and it calls `std.posix.poll` with a zero timeout at 306 |
| `Connection.dispatch` | 312 | the pump calls this, not `serve` |
| `Connection.serve` | 891 | rejected for `.poll` at 892-893, so the port never calls it |
| `Connection.nextSerial` | 287 | every outbound message |
| `Connection.methodCall` | 1080 | `GetAddress` |
| `Connection.methodCallWithFds` | 1093 | reached by `methodCall` at 1089 |
| `Connection.addMatch` | 1064 | not used by the adapter. Used by the test peer |
| `Connection.registerSignalHandler` | 1163 | the one `IsEnabled` subscription |
| `Connection.sendMessage` | 669 | every emitted signal |
| `Connection.sendReply` | 744 | the reply to an inbound method call |
| `Connection.sendError` | 821 | the reply to a failed inbound method call |
| `Connection.freeMessage` | 1137 | releases a message the port received |
| `Connection.ensureWorkersStarted` | 863 | reached from `callWithFds` at 1399, returns at 864 for `.poll` |
| `Connection.auth` | 419 | called from `initWithBackend` |
| `Connection.sayHello` | 549 | the reply is dropped at 572-573 |
| `Connection.callWithFds` | 1392 | where a D-Bus call blocks |
| `Connection.workerLoop` | 1174 | not started under `.poll` |
| `Connection.dispatchLoop` | 883 | not started under `.poll` |
| `Connection.dispatchUnsolicited` | 905 | reached from `dispatch` at 339 |
| `Connection.requestName` | 620 | not used by the adapter. Used by the test peer |
| `SocketReader` | 137 | the raw reader |
| `SocketReader.recvWithIovecs` | 203 | calls `recvmsg` at 221 |
| `SocketReader.readVec` | 181 | folds `WouldBlock` into `error.ReadFailed` at 189 |
| `MessageQueue` | 73 | `init` at 80 takes an `io`, so it composes with a zio-backed one |
| `PendingCall` | 19 | `CallState` at 13 |
| `SocketIterator` | 1451 | private. `init` at 1454, `next` at 1458, `path=` at 1460 |
| `AT_SPI_BUS_ADDRESS` read | 494 | the only way into the accessibility bus |
| the `bus_0` fallback | 498 | never reached, and wrong on this host |

#### Wire types, `GO/core.zig`

| Symbol | Line | Use |
|---|---|---|
| `value` re-export | 6 | the port reaches `GStr` and friends through it |
| `HeaderFieldValueTag` | 13 | the header field value union |
| `HeaderFieldValue` | 84 | reads `Sender`, `Path`, `Interface`, `Member`, `Signature` |
| `HeaderFieldCode` | 124 | the eight field codes |
| `HeaderField` | 137 | one header field |
| `MessageType` | 143 | `.MethodCall`, `.MethodReturn`, `.Error`, `.Signal` |
| `MessageFlag` | 156 | the serial and no-reply flags |
| `MessageHeader` | 210 | `pack` at 239 |
| `Message` | 342 | `new` at 349, `newWithFds` at 359, `pack` at 403 |

#### Values, `GO/value.zig`

| Symbol | Line | Use |
|---|---|---|
| `DBusWriter` | 5 | the `ser` sink for a hand-written wire type |
| `GStr` | 86 | `s` |
| `GPath` | 95 | `o` |
| `dbusAlignOf` | 46 | alignment inside a `ser` method |
| `GVariantTag` | 139 | the 17 variant tags |
| `GVariant` | 162 | the `v` payload of an event body |
| `Value` | 213 | the factory namespace, `isDict` at 214 |
| `reprLength` | 249 | the signature length of a Zig type |
| `getRepr` | 295 | the signature bytes |
| `Serializer` | 749 | the dispatch point for `ser` |

#### Body codec, `GO/message_utils.zig`

| Symbol | Line | Use |
|---|---|---|
| `BodyEncoder` | 10 | `encode` at 17, `body` at 63, `signature` at 68 |
| `BodyDecoder` | 74 | `fromMessage` at 110, `decode` at 139, `decodeAlloc` at 157 |

Every one of these returns `anyerror`. `AGENTS.md` forbids a bare `anyerror` in
a public signature, so `dispatch.zig` wraps each one in a declared
`DispatchError` set and maps with `inline for` over `@typeInfo`.

#### Server side, which the adapter mostly replaces

| Symbol | Line | Use |
|---|---|---|
| `common.SignalHandler` | `GO/common.zig:7` | the callback record `registerSignalHandler` appends |
| `common.InterfaceWrapper` | `GO/common.zig:14` | the shape `objects.zig` mirrors |
| `common.InterfaceWrapper.DispatchResult` | `GO/common.zig:15` | `unhandled` or `dispatched` |
| `dispatcher.getDispatchFn` | `GO/dispatcher.zig:11` | returns `anyerror!DispatchResult` |
| the member-name match | `GO/dispatcher.zig:264` | the G5 site |
| the error collapse | `GO/dispatcher.zig:298` | the G6 site |
| the unconditional `PropertiesChanged` | `GO/dispatcher.zig:205-237` | why `objects.zig` does not use it |
| `dbus_types.Signal` | `GO/dbus_types.zig:8` | `name` at 10, `interface` at 11, `path` at 12 |
| `dbus_types.Signal.trigger` | `GO/dbus_types.zig:24` | the emit path the G8 verdict uses |
| `dbus_types.signal` | `GO/dbus_types.zig:53` | not used. The port builds the struct literal so it can set all three fields |
| `dbus_types.Property` | `GO/dbus_types.zig:61` | not used. A property is a field, and a field is not a name |
| `xml_generator.generateIntrospectionXml` | `GO/xml_generator.zig:43` | the reference for what `interfaces/root.zig` must emit |
| its method loop | `GO/xml_generator.zig:49-87` | names every method from `decl.name` |
| its property loop | `GO/xml_generator.zig:105-131` | emits one property per struct field |
| `introspection.Node`, `.Interface`, `.Method` | `GO/introspection.zig:34`, `:26`, `:10` | used by the test peer only |

`xml_generator.zig:105-131` is why `interfaces/root.zig` exists. A struct
holding a bus name and a node handle would introspect as two properties of
pointer type. The port writes its XML from a table of member names.

#### Client side, `GO/proxy.zig`

| Symbol | Line | Use |
|---|---|---|
| `MethodResult` | 11 | `deinit` at 17, `reader` at 24, `expect` at 31, `expectAlloc` at 38 |
| `Proxy` | 45 | `init` at 55, `rawCall` at 65, `call` at 97, `getProperty` at 105, `setProperty` at 114, `connectSignal` at 121 |

The port uses `Proxy.call` for `GetAddress` and `Embed`, and `Proxy.getProperty`
in no place, because `Application.Id` arrives inbound.

---

## 4. The `O_NONBLOCK` fix

### 4.1 What goes wrong

zio opens every socket non-blocking. `ZIO/src/net.zig:912` is
`ev.NetOpen.init(domain, sock_type, protocol, .{ .nonblocking = true })`, and
nothing restores blocking mode afterwards.

goose reads the socket with a raw syscall. `SocketReader.recvWithIovecs` at
`GO/connection.zig:203` calls `std.posix.system.recvmsg` at
`GO/connection.zig:221`, maps `EAGAIN` to `error.WouldBlock` at
`GO/connection.zig:225`, and `SocketReader.readVec` at `GO/connection.zig:181`
folds `error.WouldBlock` into `error.ReadFailed` at `GO/connection.zig:189`.

So a zio-backed `std.Io` produces a socket on which the first read returns
`EAGAIN`, and goose reports it as a read failure. The handshake fails, and the
failure looks like a network fault. `docs/26` section 7.3 measured the flags:
`0x802` with `O_NONBLOCK` set for a zio-backed `std.Io`, against `0x2` for the
default one.

### 4.2 Why the port cannot fix it itself

`Connection.initWithBackend` connects at `GO/connection.zig:514`, then runs
`auth` at `GO/connection.zig:537`, then `sayHello` at `GO/connection.zig:539`,
all before it returns. The port never holds the descriptor until after both
have run. The flag therefore has to be cleared inside goose.

The port also cannot pass a different `std.Io` for the connect and a zio-backed
one afterwards, because `initWithBackend` takes one `io` at
`GO/connection.zig:474` and uses it for the connect at 514, for the reader at
`GO/connection.zig:534`, and for every condition variable.

### 4.3 Where the four lines go

Insert immediately after `GO/connection.zig:514`, which is
`const socket = try unix_addr.connect(io);` and before the `var conn = Connection{`
literal at `GO/connection.zig:516`.

```zig
{
    const fl = std.posix.system.fcntl(socket.socket.handle, std.posix.F.GETFL, @as(usize, 0));
    const mask = @as(@TypeOf(fl), 1 << 11); // 04000 octal on Linux
    const cleared: usize = @intCast(fl & ~mask);
    _ = std.posix.system.fcntl(socket.socket.handle, std.posix.F.SETFL, cleared);
}
```

`docs/26` section 7.4 measured this block. With it, the same zio task completes
the handshake, answers `GetId`, and receives a live signal.

Two constraints on the block, both from `AGENTS.md`. It must use
`std.posix.system` rather than `std.posix` so the return value is the raw
`c_int` and `errno` is not consumed. It must read back the flags after setting
them and return `error.SocketStillNonBlocking` if `O_NONBLOCK` survives, because
a silent failure is the failure this whole section is about.

### 4.4 What it costs

| Cost | Measure |
|---|---|
| Lines changed in a third-party file | 4, plus 2 for the read-back assertion |
| Files touched | 1, at 1 location |
| Behaviour changed | none. A blocking descriptor is what a synchronous D-Bus client expects |
| Carried how | a `zig build` patch step, per `docs/30` section 7.3 record R5 |
| Guard | the step asserts the file is byte-identical to the pinned hash before rewriting, and asserts the block is present after |
| Symptom when the guard fails | `error.ReadFailed` during the SASL handshake, which reads as a network fault |

The fifth goose change rides in the same patch: keep the `Hello` reply at
`GO/connection.zig:572-573` and expose the unique name. §3.1.

---

## 5. The runtime

`docs/20-zio-and-zig-io.md` section 1 settles the shape. `zio` implements
`std.Io`. It does not replace it. The rule that follows is in
`docs/20` section 1.4: library code takes `std.Io`, and `*zio.Runtime` appears
only where a task must be spawned, a group driven, or a timeout armed.

This adapter is the first place `*zio.Runtime` appears at all.
`docs/30` section 7.1 allows it in exactly three modules.

### 5.1 Creating the runtime

| Step | Symbol | Line |
|---|---|---|
| create | `zio.Runtime.init(gpa, .{})` | `ZIO/src/runtime.zig:1620` |
| release | `Runtime.deinit` | `ZIO/src/runtime.zig:1759` |
| the `std.Io` the port passes to goose | `zio.fromRuntime(rt, .blocking)` | `ZIO/src/io.zig:138` |
| the mode enum | `Mode`, values `regular` and `blocking` | `ZIO/src/io.zig:118` |
| recover a runtime from an `Io` | `Runtime.fromIo` | `ZIO/src/runtime.zig:2082` |

Two traps.

**`Runtime.io` is the wrong call.** `ZIO/src/runtime.zig:2067` returns
`fromRuntime(self, .regular)`. `.regular` mode dispatches through the
completion queue, which is right for ordinary zio code and wrong for goose,
whose reads are raw syscalls that never reach the queue. `runtime.zig` calls
`zio.fromRuntime(rt, .blocking)` and stores the result itself.

**The three re-exports do not exist yet.** `ZIO/src/zio.zig:101` re-exports
only `debug_io`. `fromRuntime` at `ZIO/src/io.zig:138`, `toRuntime` at
`ZIO/src/io.zig:146`, and `Mode` at `ZIO/src/io.zig:118` are not reachable
through the module root, and adding `src/io.zig` as a second module fails
because Zig forbids one file in two modules. `runtime.zig` therefore declares a
three-line local wrapper over `@import("io.zig")`, and `docs/30` section 11 row 3
records the upstream pull request. `docs/30` section 7.2 part 1 fixes this: the
port does not patch zio's source.

`Runtime.fromIo` at `ZIO/src/runtime.zig:2082` checks the vtable pointer
identity at `:2084` and returns `null` for a foreign backend. Every call site
must handle that `null`, because a unit test may hand the adapter a
`std.Io.Threaded`.

### 5.2 Spawning a task

| Need | Symbol | Line |
|---|---|---|
| a task that can await | `zio.spawn` | `ZIO/src/runtime.zig:1492` |
| a task that blocks the executor | `zio.spawnBlocking` | `ZIO/src/runtime.zig:1506` |
| the same, as methods | `Runtime.spawn`, `Runtime.spawnBlocking` | `ZIO/src/runtime.zig:1816`, `:1850` |
| join a task | `JoinHandle.join` | `ZIO/src/runtime.zig:193` |
| cancel a task | `JoinHandle.cancel` | `ZIO/src/runtime.zig:260` |
| sleep | `zio.sleep` | `ZIO/src/runtime.zig:1556` |
| the group form | `Group.spawn`, `Group.wait`, `Group.cancel` | `ZIO/src/group.zig:118`, `:190`, `:207` |

Both free functions panic outside a task, so `runtime.zig` calls the methods.
The port uses `Runtime.spawn` and keeps the `JoinHandle`, because
`Group.spawn` returns `!void` and no handle, so a task error is only visible
through the group.

Upstream spawns exactly two tasks, both loops that call
`Connection.executor().tick()` forever, at
`UP/adapters/unix/src/context.rs:174-182` and
`UP/adapters/unix/src/atspi/bus.rs:52-60`. The port spawns one. The session connection answers one
call and is then closed, per `docs/30` section 7.2 part 4 step 5, so only the
accessibility connection survives to be pumped. `pump.zig` replaces both loops,
because goose in `.poll` mode has no internal executor to tick and `dispatch` is
what drains the socket.

### 5.3 What the rest of the port sees

`std.Io`, and nothing else. `pump.zig` and `bus.zig` take `io: std.Io`.
`interfaces/*.zig`, `objects.zig`, `dispatch.zig`, `node.zig`,
`change_handler.zig`, `platform_adapter.zig`, `message.zig` and `adapter.zig`
take no `Io` at all, because none of them performs I/O.

A task that must block goes through `Runtime.spawnBlocking`, because under
`.poll` backend every D-Bus call blocks the calling thread. `callWithFds` at
`GO/connection.zig:1392` reaches `ensureWorkersStarted` at
`GO/connection.zig:1399`, which returns immediately at
`GO/connection.zig:864` for `.poll`, and then reads the socket itself. The guard at
`GO/connection.zig:1404` tests `self.backend == .poll or self.worker_thread == null`,
which the port always satisfies, and the loop body starts at
`GO/connection.zig:1405`.

Two consequences follow, and both are design constraints.

| Consequence | The rule |
|---|---|
| a signal handler must not make an outbound call | Under `.poll`, a nested `methodCall` reads the same socket and can consume the outer call's reply. `docs/13` section 7.4 records this. `doAction` therefore enqueues and returns, which is what `docs/30` section 5.1 already requires of a queued handler |
| a tree update must not block the pump for long | The pump task drains the message channel between `dispatch` calls, so an update runs on the pump task. The application must not call `Adapter.deinit` from inside an `ActionHandler` |

### 5.4 How cancellation reaches a blocked D-Bus read

Not through `JoinHandle.cancel`. The chain has no cancellation point.

1. A task calls `methodCall`, which reaches `callWithFds` at
   `GO/connection.zig:1392`.
2. `callWithFds` enters the inline loop. The guard at `GO/connection.zig:1404`
   tests `self.backend == .poll or self.worker_thread == null`, which the port
   always satisfies, and `while (true)` is at `GO/connection.zig:1405`. The loop
   ends at `GO/connection.zig:1433`.
3. The read reaches `readNextMessage` at `GO/connection.zig:1217`, then
   `SocketReader.streamImpl` at `GO/connection.zig:173`, then `readVec` at
   `GO/connection.zig:181`, then the raw `recvmsg` at `GO/connection.zig:221`.
4. `recvmsg` blocks. No await, no timeout, no cancellation point.

`JoinHandle.cancel` at `ZIO/src/runtime.zig:260` takes effect at the task's next
cancellation point. That point does not exist, so the cancel is recorded and
delivered never.

`Connection.close` at `GO/connection.zig:577` is worse than useless here. It calls
`wakeAllWithError` at `GO/connection.zig:596`, which reaches only tasks parked on
the connection's condition variable, and the blocked task is not one of them: it
sits in its own `while (true)` at `GO/connection.zig:1405`. `close` then frees
`pending_calls` and `dispatch_queue` at `GO/connection.zig:598-599`, while the
blocked task registered a `PendingCall` at `GO/connection.zig:1395` and still reads
`pending.reply` at `GO/connection.zig:1406`. That is a use-after-free.

The port needs one line of its own, in `bus.zig`.

```zig
pub fn cancelReceive(self: *Bus) void {
    std.posix.shutdown(self.conn.getFd(), .recv) catch {};
}
```

`recvmsg` then returns 0, `recvWithIovecs` returns 0 at
`GO/connection.zig:229`, and `readVec` turns 0 into `error.EndOfStream` at
`GO/connection.zig:193`. The blocked task unwinds with a declared error, the
`spawnBlocking` task settles, and `Connection.close` runs afterwards in order.

So the answer is: **cancellation reaches a blocked D-Bus read by shutting the
receive side down, not by cancelling the task.** `Bus.cancelReceive` is the
whole mechanism, and `Adapter.deinit` calls it first.

The teardown order is fixed, because `Runtime.deinit` at
`ZIO/src/runtime.zig:1759` asserts every task has settled.

1. `Bus.cancelReceive`, which releases every blocked call.
2. `Pump.stop`, which shuts down the group.
3. Join the pump task and every blocking call task.
4. `Bus.deinit`, which calls `Connection.close` at `GO/connection.zig:577`.
5. `Runtime.deinit`.

Nothing reads a clock. `zio.now` at `ZIO/src/runtime.zig:1551` is not called
from `src/`, per `docs/30` section 8.

---

## 6. What can be verified on this host, and how

The accessibility bus is live and answers. The commands below ran on this
node, uid 33156, and their output is quoted. `busctl`, `dbus-send`,
`dbus-daemon`, `dbus-run-session`, `dbus-broker-launch` and `python3` are all
at `/bin`.

### 6.1 The two-step discovery

Step one, the session bus answers the address query.

```
$ busctl --user call org.a11y.Bus /org/a11y/bus org.a11y.Bus GetAddress
s "unix:path=/run/user/33156/at-spi/bus"
```

What it proves: the `org.a11y.Bus` proxy call the adapter must make is
reachable, and its reply decodes as one `GStr`. This is step 2 of
`docs/30` section 7.2 part 4.

Step two, the status flag decides whether to go on.

```
$ busctl --user get-property org.a11y.Bus /org/a11y/bus org.a11y.Status IsEnabled
b false
```

What it proves: the `PropertiesChanged` subscription at
`UP/adapters/unix/src/context.rs:184-185` has something to watch. It also
records a fact an implementer needs. **`IsEnabled` is `false` on this host right
now.** `UP/adapters/unix/src/context.rs:147-152` maps a change of `false` to no
bus, so upstream's adapter would sit inactive until a screen reader is present.
A test must set `AT_SPI_BUS_ADDRESS` directly, as `docs/13` section 8.1 argues,
rather than depend on `IsEnabled` being `true`.

Step three, the resolved address reaches the bus.

```
$ busctl --address=unix:path=/run/user/33156/at-spi/bus list
NAME                      PID PROCESS         USER     CONNECTION UNIT                SESSION DESCRIPTION
:1.58                   65246 busctl           user :1.58       session-77176.scope 77176   -
:1.6                    24801 at-spi2-registr user :1.6       user@33156.service  -       -
org.a11y.atspi.Registry 24801 at-spi2-registr user :1.6       user@33156.service  -       -
org.freedesktop.DBus    55300 at-spi-bus-laun user -          user@33156.service  -       -
```

What it proves: the address from step one is usable, and only the registry and
the bus driver are on the bus. **No AT-SPI application is present**, which is
why §6.4 needs a synthetic peer.

### 6.2 One method call against the registry

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

```
$ busctl --address=unix:path=/run/user/33156/at-spi/bus call org.a11y.atspi.Registry /org/a11y/atspi/registry org.a11y.atspi.Registry GetRegisteredEvents
a(ss) 0
```

What they prove: an inbound method call, its reply, and `Introspect` all work
against a real peer over the a11y socket. `GetRegisteredEvents` is the success
case, an empty `a(ss)` that is eight zero bytes on the wire. `Introspect` is how
the port learns a peer's surface when a test needs it.

The same call on the wrong path gives the error case, which proves the adapter
must read `message_type` rather than trust a returned Zig error.

```
$ busctl --address=unix:path=/run/user/33156/at-spi/bus call org.a11y.atspi.Registry /org/a11y/atspi/null org.a11y.atspi.Registry GetChildren
Call failed: Method "GetChildren" with signature "" on interface "org.a11y.atspi.Registry" doesn't exist
```

What it proves: the registry object is at `/org/a11y/atspi/registry`, and a D-Bus
error arrives as an ordinary message with `message_type` `.Error` and an
`ErrorName` header field. §1.9's five error names travel the same way outbound.

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

What it proves: the three paths of §1.1 are the paths the registry knows about,
and no accessible object exists on this bus yet.

### 6.3 The signal path, with a synthetic peer

Nothing on this bus emits `org.a11y.atspi.Event.Object`. `docs/26` section 4
waited six seconds on an idle bus and received zero signals, with both
`AddMatch` calls succeeding. The route around it is a peer the test owns.

The cheapest signal needs no hand-built body. The registry emits
`org.a11y.atspi.Registry.EventListenerDeregistered` when any client leaves the
a11y bus, so a second process that connects and exits is enough.

| Step | Command or action | What it proves |
|---|---|---|
| 1 | Start the port's signal test, which opens the a11y connection and registers `EventListenerDeregistered` through `registerSignalHandler` at `GO/connection.zig:1163` | the receive path is live |
| 2 | In another shell, run `busctl --address=unix:path=/run/user/33156/at-spi/bus list`, which connects and exits | the peer |
| 3 | The test must see exactly one signal, body `ss`, first string the leaving unique name, second string empty | the body decodes and the name matches |
| 4 | In parallel, run `busctl --address=unix:path=/run/user/33156/at-spi/bus monitor org.a11y.atspi.Registry` | the same signal on the wire, independent of the port |

For an event signal the peer must build the body itself. It owns a name through
`requestName` at `GO/connection.zig:620`, then builds a `Signal` message with
`core.MessageHeader` at `GO/core.zig:210` and sends it through
`sendMessage` at `GO/connection.zig:669`. `docs/26` section 4 did exactly this
and delivered the message back to the sender.

**The body must carry five arguments.** The AT-SPI2 reference XML declares `s`,
`i`, `i`, `v`, `a{sv}` for all 57 event signals, that is `siiva{sv}`. §1.7
settles it and §1.10 row K2 carries the census. `docs/26` section 4 recorded
`siivso` and was corrected on 2026-10-05. A peer that builds a four-argument
body proves nothing about the shipped encoder.

### 6.4 The `Embed` call, and why the port cannot fake it

`Embed` is the one call the adapter cannot delegate to `busctl`. Its first
argument must be the caller's own unique bus name, as the AT-SPI reference XML
states and as `UP/adapters/unix/src/atspi/bus.rs:88` passes.

What happens when it is not. Reproduced twice on this node.

```
$ pgrep -f 'at-spi2-registryd'
... 46843
$ busctl --address=unix:path=/run/user/33156/at-spi/bus introspect org.a11y.atspi.Registry /org/a11y/atspi/accessible/root
Failed to parse bus message: No such device or address
$ pgrep -f 'at-spi2-registryd'
... 46843
$ busctl --address=unix:path=/run/user/33156/at-spi/bus call org.a11y.atspi.Registry /org/a11y/atspi/accessible/root org.a11y.atspi.Socket Embed ss ":1.12345" "/org/a11y/atspi/accessible/root"
Call failed: Remote peer disconnected
$ pgrep -f 'at-spi2-registryd'
        (46843 is gone)
```

The `Introspect` on the same path, with the same `IsEnabled` value and the same
registry process, leaves it alive. `Embed` with a plug name that is not the
caller's kills it. The launcher restarts it, which is why the name then shows
as `(activatable)`.

Three facts follow, and all three are load-bearing.

| Fact | Consequence |
|---|---|
| The registry aborts on a mismatched plug name | Any harness that substitutes a literal unique name destroys the accessibility registry on the developer's machine. A test that does this must be refused |
| `busctl` cannot supply its own unique name | The `Embed` integration test can only be written in Zig, where the port has the name |
| goose never learns that name | `sayHello` drops the reply at `GO/connection.zig:572-573`. This is the tenth gap in §3.1, and without the `sayHello` patch the adapter cannot register at all |

The test therefore asserts on the three things it can assert from inside the
process.

| Assert | Proves |
|---|---|
| `GetAddress` returned a string that `SocketIterator` can turn into a path | §6.1 step one, end to end through the port |
| `Embed` returned a `(so)` whose path is the desktop root, and the registry did not drop the connection | the handshake at `UP/adapters/unix/src/atspi/bus.rs:86-90` |
| the adapter's unique name equals the one it passed to `Embed` | the fix for the tenth gap, asserted on the value that killed the registry twice |

### 6.5 The `fcntl` fix, proved in a test

The four lines of §4.3 are proved by one test, not by an inspection.

| Step | Action | What it proves |
|---|---|---|
| 1 | Build a `zio.Runtime`, take `fromRuntime(rt, .blocking)`, connect with `initWithBackend(allocator, .Accessibility, io, vars, .poll)` | the descriptor is non-blocking without the patch, and `error.ReadFailed` comes back during the handshake |
| 2 | Apply the patch and rerun | the handshake completes and `GetId` answers |
| 3 | Assert `fcntl(F_GETFL) & O_NONBLOCK == 0` on `conn.getFd()` after construction | the descriptor is in the state goose needs, checked rather than inferred |

`docs/30` section 7.3 requires the build step to assert the file is
byte-identical to the pin before rewriting it. Step 1 is the red run that makes
that guard meaningful, per `AGENTS.md` section 7.

---

## 7. The upstream items with no counterpart

### 7.1 `accesskit_winit` is out of scope, confirmed

`accesskit_winit` is a **toolkit bridge**, not a platform adapter. Confirmed
against `docs/12-accesskit-adapters.md` and against the upstream tree.

| Evidence | Line | Says |
|---|---|---|
| `docs/12:56` | the inventory row | Kind is "toolkit integration", and both dependency columns read "none itself; it delegates" |
| `docs/12:825` | the section heading | "### 6.1 What a toolkit integration adds over a platform adapter" |
| `docs/12:861-863` | the recommendation | "**Recommendation: no. Do not port `accesskit_winit`.** Reason: winit is a Rust crate with no Zig equivalent that the port could bind to, and the port must build with no Rust." |
| `docs/12:1315` | the portability table | The `accesskit_winit` row reads "**Recommendation: not ported.** See section 6.2." |
| `UP/adapters/winit/src/lib.rs:127-129` | the source | `pub struct Adapter { inner: platform_impl::Adapter }`. It holds a platform adapter, it does not implement one |
| `UP/adapters/winit/src/platform_impl/unix.rs:6` | the source | `use accesskit_unix::Adapter as UnixAdapter;` |

It adds two things, both of which belong to the application. Three ways to
supply handlers (`UP/adapters/winit/src/lib.rs:149`, `:190`, `:229`) and one
event translator (`process_event` at `:254`, `update_if_active` at `:264`).
`docs/12:865` says "The functionality it adds is small and belongs in the
application, not in the library", and `docs/12:876-879` says the port defines a
small `Adapter` struct per platform instead. **631 upstream lines, no milestone,
and it is excluded rather than deferred.** No other adapter crate depends on it.
`grep -rn accesskit_winit` over `UP/adapters/*/Cargo.toml` returns only the
crate's own `name` field, at `UP/adapters/winit/Cargo.toml:2`.

The two channels that replace its Unix half are `set_root_window_bounds` at
`UP/adapters/unix/src/adapter.rs:173` and `update_window_focus_state` at
`UP/adapters/unix/src/adapter.rs:222`. Both are ports in their own right, and
`docs/12:96-97` states the consequence: "The application pushes geometry and
focus in through two methods and the adapter does the rest over D-Bus." On this
host nothing else supplies them. See §8.

### 7.2 Every part the port drops

| Upstream item | Line | Lines | Why it has no counterpart |
|---|---|---:|---|
| the `simplified` module | `UP/adapters/atspi-common/src/lib.rs:15-16`, `UP/adapters/atspi-common/Cargo.toml:15` | 977 | Feature-gated behind `simplified-api`. `grep -rn "simplified" --include=Cargo.toml UP/` finds no crate that enables it, so it is not compiled at this pin. `docs/12:1353` calls it "an in-process AT-SPI client for tests" and says delete |
| the filter re-export | `UP/adapters/atspi-common/src/filters.rs:6` | 6 | One line: `pub(crate) use accesskit_consumer::common_filter as filter;`. The port names `consumer/filter.zig` directly |
| the `AdapterCallback` trait | `UP/adapters/atspi-common/src/callback.rs:9-15` | 15 | It becomes a struct of function pointers. `docs/12:1064` records "delete; a struct of function pointers", and `docs/30` section 6.1 draws the vtable |
| the `Executor` and `Task` wrappers | `UP/adapters/unix/src/executor.rs:28-158` | 158 | It wraps `async-executor` and `tokio`. The port has one runtime, so `runtime.zig` is four declarations against `zio` |
| the two `block_on` definitions | `UP/adapters/unix/src/util.rs:11-24` | 14 | One builds a `futures_lite` loop, the other a `tokio` runtime. The port has no blocking call outside `spawnBlocking` |
| the `async-io` and `tokio` features | `UP/adapters/unix/Cargo.toml:14-17` | 4 | The duality is what `docs/12:1346` deletes: "one runtime, `zio`" |
| the `Serialize` impl for `ObjectId` | `UP/adapters/unix/src/atspi/object_id.rs:47-57` | 11 | zbus needed it to build the `Embed` plug. The port passes the two halves explicitly |
| the `Type` impls for `Rect` and `Action` | `UP/adapters/atspi-common/src/rect.rs:11-16`, `action.rs:7-13` | 13 | Replaced by a `ser` method and a comptime signature, which is what `GO/value.zig:249` and `:295` compute |
| the `phf` attribute map | `UP/adapters/atspi-common/src/text_attributes.rs:68-79` | 12 | A compile-time map from a string to a getter. The port uses an `inline for` over a `switch`, which is the same sweep `AGENTS.md` section 3 wants |
| `next_adapter_id` and its counter | `UP/adapters/atspi-common/src/adapter.rs:352-358` | 7 | A process-global `AtomicUsize`. The id becomes a parameter, `docs/12:1079` |
| `Adapter::with_id` | `UP/adapters/atspi-common/src/adapter.rs:397-417` | 21 | `docs/12:1081`: "delete; `new` takes the id" |
| `Adapter::with_wrapped_action_handler` | `UP/adapters/atspi-common/src/adapter.rs:419-441` | 23 | `docs/12:1082`: "merge into `init`" |
| the six `resolve` helpers | `UP/adapters/atspi-common/src/node.rs:729-822` | 94 | Each takes a closure over a tree guard. `docs/12:1107`: "delete; inline the lock, upgrade and unlock" |
| the `Weak<Context>` | `UP/adapters/atspi-common/src/node.rs:718` | 1 | An implicit lifetime. `AGENTS.md` section 6 turns a lifetime into a parameter or a named pointer |
| the two `OnceLock` statics | `UP/adapters/unix/src/context.rs:33-34` | 2 | Process-global state, which `docs/30` section 5.2 replaces with `Adapter` fields |
| the `OnceLock` desktop field | `UP/adapters/unix/src/atspi/bus.rs:35` | 1 | The same. It becomes `?DesktopRef`, written once during activation |
| `thread::spawn` and `block_on` | `UP/adapters/unix/src/context.rs:55-59` | 5 | Becomes `Runtime.spawn` |
| the two `tick()` loops | `UP/adapters/unix/src/context.rs:174-182`, `UP/adapters/unix/src/atspi/bus.rs:52-60` | 18 | One pump task replaces both. `docs/12:985-993` maps them to one zio task per goose connection |
| `Task::detach` | `UP/adapters/unix/src/executor.rs:105-121` | 17 | The port joins every task before `Runtime.deinit` |
| `unreachable!` | `UP/adapters/unix/src/context.rs:289` | 1 | Becomes a member of the declared error set, per `AGENTS.md` section 6 |
| `panic!` | `UP/adapters/unix/src/context.rs:63` | 1 | Becomes a returned error |
| `zbus_error_is_unrecoverable` | `UP/adapters/unix/src/atspi/bus.rs:505-510` | 6 | Merged into `error.zig`. `docs/12:1387-1393` gives the shape: three named members plus a default arm |
| `map_or_ignoring_recoverable_error` | `UP/adapters/unix/src/atspi/bus.rs:512-525` | 14 | A `catch` into a declared set |
| the `add_subtree` and `remove_subtree` recursion | `UP/adapters/atspi-common/src/adapter.rs:84-89`, `:114-119` | 12 | `docs/12:1395-1399` forces the choice: a maximum depth with `error.TreeTooDeep`, or a fixed-capacity worklist |
| the `Box<dyn AdapterCallback>` and `Arc<dyn ActionHandlerNoMut>` | `UP/adapters/atspi-common/src/adapter.rs:362`, `UP/adapters/atspi-common/src/context.rs:38` | 2 | Two vtable structs. `docs/30` section 6.1 |
| `zbus::Address` parsing | `UP/adapters/unix/src/atspi/bus.rs:47` | 1 | The address arrives as a `GStr` and goes straight into the `Environ.Map` |
| the `atspi` and `atspi-common` crates | `UP/adapters/unix/Cargo.toml:22`, `UP/adapters/atspi-common/Cargo.toml:20` | 0 | The wire enums are declared in `wire.zig`. `UP/adapters/atspi-common/src/lib.rs:21-24` re-exports nine of them |
| the Rust test modules | `UP/adapters/atspi-common/src/adapter.rs:625-825`, `UP/adapters/unix/src/atspi/interfaces/cache.rs:115-312` | 397 | The port writes Zig tests against the same behaviour. The upstream assertions are the oracle for what to assert, and they are read, not run |

**Not dropped, and not to be dropped.** The interface-delta computation at
`UP/adapters/atspi-common/src/adapter.rs:308-314` is a symmetric difference
between the old and new interface sets. `docs/13` section 3.16 is right that
sending the whole set on every update would multiply traffic. Port it as it
stands.

---

## 8. What this document leaves to `docs/30` and `docs/40-plan`

| # | Question | Owner | Why it is not decided here |
|---|---|---|---|
| 1 | Does the event body carry five arguments or four | `docs/40-plan.md` | §1.10 row K2 settles it against the XML and marks the remaining half `[INFERENCE]`. Proving it needs a live AT-SPI client, which this host does not have |
| 2 | Is the tenth goose gap, the missing unique name, patched in or worked around | `docs/30` | §3.1 states the defect and the cost. `docs/30` section 7.3 already owns how a goose patch is carried, so this rides in the same step. The decision is whether the adapter may depend on a two-patch goose |
| 3 | Does the pump task also drain the message channel | `docs/30` | §5.3 and §2.3 depend on it, because it is what removes the G1b race without a mutex. If the answer is no, `objects.zig` needs one |
| 4 | A fixed-capacity worklist or a maximum depth with `error.TreeTooDeep` | `docs/30` | `docs/12:1395-1399` hands this to `docs/30`. It governs `addSubtree`, `removeSubtree`, `mapDescendants` and `mapDescendantCacheNodes` |
| 5 | Where a Zig application gets window bounds and focus on this host | `docs/30`, `docs/40-plan.md` | `local://zaccesskit-risk-register.md` R6 requires this to be named. The AT-SPI adapter has no source for either value, and this host has no X11 or Wayland client to ask. The adapter exposes `setRootWindowBounds` at `UP/adapters/unix/src/adapter.rs:173` and `updateWindowFocusState` at `:222`, and the application supplies them |
| 6 | The module count and the milestone order for the adapter | `docs/40-plan.md` | §2.2 lists 30 modules and names the five deletions. `docs/30` section 3.3 leaves the number to `docs/40-plan.md` |
| 7 | Whether the `SocketIterator` widening covers `guid=` and `tcp:` | `docs/40-plan.md` | §3.1 gap G4 requires `unix:abstract=`. `docs/26` section 8.1 item 5 names the rest as an inference that this host cannot test |
