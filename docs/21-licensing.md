# Licensing and provenance

Port-authored code and changes are MIT, Copyright (c) 2026 Janis Gertulla;
see [LICENSE](../LICENSE). Upstream-owned material retains its own terms.
The distribution license bundle is included at the repository root:
[LICENSE-MIT](../LICENSE-MIT), [LICENSE-APACHE](../LICENSE-APACHE),
[LICENSE.chromium](../LICENSE.chromium), [NOTICE.md](../NOTICE.md), and
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Upstream source

| Project | Source revision | Version |
|---|---|---|
| [AccessKit](https://github.com/AccessKit/accesskit) | `466e24e252103f4d82bd6fbab98141b551e46e0c` | 0.25.1 |
| [AccessKit C](https://github.com/AccessKit/accesskit-c) | `8b6ed37c20ed4c59390e253407983333053662ba` | 0.23.1 |

AccessKit-authored material uses `MIT OR Apache-2.0`. Significant portions derive
from Chromium and the Flutter engine and carry additional BSD-style notices.
The Chromium terms are file-scoped, not a third alternative to MIT or Apache-2.0.
AccessKit's `adapters/winit/**` is Apache-2.0 only; this port has no winit adapter.
The LGPL-2.1 terms in accesskit-c cover its Meson build system only. This port
uses Zig's build system and does not copy the Meson build.

The following upstream files carry Chromium or Flutter derivation notices.
Retain each holder, year, and notice when distributing translated material.

| Upstream AccessKit path | Additional holder | Year |
|---|---|---|
| `accesskit/src/lib.rs` | The Chromium Authors | 2018 |
| `accesskit_consumer/src/iterators.rs` | The Chromium Authors | 2018 |
| `accesskit_consumer/src/node.rs` | The Chromium Authors | 2021 |
| `adapters/atspi-common/src/adapter.rs` | The Chromium Authors | 2017 |
| `adapters/atspi-common/src/node.rs` | The Chromium Authors | 2017 |
| `adapters/android/src/node.rs` | The Chromium Authors | 2018 |
| `adapters/macos/src/node.rs` | The Chromium Authors | 2018 |
| `adapters/windows/src/node.rs` | The Chromium Authors | 2021 |
| `adapters/android/src/adapter.rs` | The Flutter Authors | 2013 |
| `adapters/android/src/event.rs` | The Flutter Authors | 2013 |
| `adapters/ios/src/adapter.rs` | The Flutter Authors | 2013 |
| `adapters/ios/src/node.rs` | The Flutter Authors | 2013 |

Other upstream derivations have separate notices:

| Upstream path | Origin and holder | Terms |
|---|---|---|
| AccessKit `accesskit/src/geometry.rs` | kurbo; Copyright 2018 The kurbo Authors | MIT OR Apache-2.0 |
| AccessKit `adapters/android/src/inject.rs` | jni-rs; Copyright 2016 Prevoty, Inc. and jni-rs contributors | MIT OR Apache-2.0 |
| AccessKit `adapters/unix/src/executor.rs` | zbus; Copyright 2024 Zeeshan Ali Khan | MIT |
| AccessKit C `src/lib.rs` | rustls-ffi; Copyright (c) 2021, Jacob Hoffman-Andrews | Apache-2.0 OR ISC OR MIT |

The port uses the available MIT option for the derivations above. Their
copyright notices and selected terms are retained in `NOTICE.md` and
`LICENSE-MIT`. The upstream rustls-ffi derivation header refers to an absent
`LICENSE-ISC`; that alternative is not needed for the MIT selection. The
generated upstream C header omits some Chromium and Flutter copyright lines;
the complete per-file inventory is retained in this port's `NOTICE.md`.

## Dependencies

The package fetches [zio](https://github.com/lalinsky/zio) and
[zigwin32](https://github.com/marlersoft/zigwin32); exact pins are in
`build.zig.zon`. zio carries MIT notices for Lukas Lalinsky and Zig contributors.
Its package path list omits its license file, so the full pinned zio and Zig
contributor notices are retained in `THIRD_PARTY_NOTICES.md` for distributions
that bundle dependency code. zigwin32 includes its `LICENSE` in its package;
its notice and MIT terms are also retained in `THIRD_PARTY_NOTICES.md`. D-Bus
encoding is implemented in this repository; goose is not a dependency.

## Distribution

Source and binary distributions containing the header or derived code must
carry `LICENSE`, `LICENSE-MIT`, `LICENSE-APACHE`, `LICENSE.chromium`,
`NOTICE.md`, and `THIRD_PARTY_NOTICES.md`. All six files are included in the
Zig package path list. Retain upstream copyright, permission, derivation,
and change notices. The public C header's existing notices remain unchanged.

The root MIT grant applies to the port's authored code and changes, not to
third-party ownership. AccessKit's MIT OR Apache-2.0 offer remains intact;
Chromium and Flutter BSD obligations are separate. Native Apple and Microsoft
SDK terms remain separate from this license bundle. The project does not
claim endorsement by AccessKit, Google, Apple, or Microsoft.
