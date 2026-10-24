# Licensing and provenance

The project has not chosen a licence for port-authored code. This inventory does
not grant a licence. Distribution needs a review of upstream notices, translated
files, dependency licences, and native SDK terms.

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

The upstream rustls-ffi derivation header refers to `LICENSE-ISC`, which is absent
from the pinned AccessKit C tree. The generated upstream C header also lacks the
Chromium and Flutter copyright lines. Neither omission removes the applicable
upstream conditions from derived material.

## Dependencies

The package fetches [zio](https://github.com/lalinsky/zio) and
[zigwin32](https://github.com/marlersoft/zigwin32); exact pins are in
`build.zig.zon`. zio carries MIT notices for Lukas Lalinsky and Zig contributors.
Its package path list omits its licence file, so a binary distribution must
obtain and retain that text separately. zigwin32 includes its `LICENSE` in its
package. D-Bus encoding is implemented in this repository; goose is not a
dependency.

## Distribution

Retain upstream copyright, permission, derivation, and change notices. Include
the applicable full licence texts with source and binary distributions. The
repository does not yet contain the complete distribution licence bundle or a
port-authored grant. Review the derivative-work scope and Apple and Microsoft
SDK terms before release. The project does not claim endorsement by AccessKit,
Google, Apple, or Microsoft.
