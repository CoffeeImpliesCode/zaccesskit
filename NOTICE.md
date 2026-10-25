# zaccesskit notices

Copyright (c) 2026 Janis Gertulla. Port-authored code is MIT; see [LICENSE](LICENSE).

## AccessKit and AccessKit C

This is a Zig port, not an unmodified upstream distribution. Upstream Rust
implementations were translated and reorganized into `src/schema/`,
`src/consumer/`, `src/adapters/`, and `src/capi/`. The C interface is in
`include/zaccesskit.h`; its existing change notice describes its changes.
Keep source copyright, derivation, and change notices when redistributing.

- [AccessKit 0.25.1](https://github.com/AccessKit/accesskit/tree/466e24e252103f4d82bd6fbab98141b551e46e0c).
- [AccessKit C 0.23.1](https://github.com/AccessKit/accesskit-c/tree/8b6ed37c20ed4c59390e253407983333053662ba).
- Copyright The AccessKit Authors. All rights reserved. Source notices include
  Copyright 2021 The AccessKit Authors, Copyright 2023 The AccessKit Authors,
  and Copyright 2025 The AccessKit Authors.
- AccessKit-authored material is `MIT OR Apache-2.0`, at the recipient's option.
  Both upstream grants are supplied in [LICENSE-MIT](LICENSE-MIT) and
  [LICENSE-APACHE](LICENSE-APACHE). The port uses the available MIT option;
  this does not remove the upstream dual-license offer or the BSD obligations.
- AccessKit's Apache-only winit adapter and AccessKit C's LGPL-2.1 Meson build
  system are not copied into this port.

## Chromium and Flutter derivations

The following are exact upstream AccessKit paths and their additional copyright
notices. Port areas identify the translated subsystem, not a one-to-one file map.
These portions retain BSD-3-Clause terms in [LICENSE.chromium](LICENSE.chromium),
separately from the MIT OR Apache-2.0 choice for AccessKit-authored material.
The upstream Flutter derivation headers also refer to `LICENSE.chromium`.

| Upstream AccessKit path | Copyright notice (all rights reserved) | Port area |
|---|---|---|
| `accesskit/src/lib.rs` | Copyright 2018 The Chromium Authors. | `src/schema/` |
| `accesskit_consumer/src/iterators.rs` | Copyright 2018 The Chromium Authors. | `src/consumer/iterators/` |
| `accesskit_consumer/src/node.rs` | Copyright 2021 The Chromium Authors. | `src/consumer/node_ref/`, `src/consumer/text/` |
| `adapters/atspi-common/src/adapter.rs` | Copyright 2017 The Chromium Authors. | `src/adapters/atspi/` |
| `adapters/atspi-common/src/node.rs` | Copyright 2017 The Chromium Authors. | `src/adapters/atspi/` |
| `adapters/android/src/node.rs` | Copyright 2018 The Chromium Authors. | `src/adapters/android/` |
| `adapters/macos/src/node.rs` | Copyright 2018 The Chromium Authors. | `src/adapters/macos/` |
| `adapters/windows/src/node.rs` | Copyright 2021 The Chromium Authors. | `src/adapters/windows/` |
| `adapters/android/src/adapter.rs` | Copyright 2013 The Flutter Authors. | `src/adapters/android/` |
| `adapters/android/src/event.rs` | Copyright 2013 The Flutter Authors. | `src/adapters/android/` |
| `adapters/ios/src/adapter.rs` | Copyright 2013 The Flutter Authors. | `src/adapters/ios/` |
| `adapters/ios/src/node.rs` | Copyright 2013 The Flutter Authors. | `src/adapters/ios/` |

`include/zaccesskit.h` also retains Copyright 2015 The Chromium Authors. All
rights reserved, for the role list and descriptions, under `LICENSE.chromium`.

Upstream projects: [Chromium](https://chromium.googlesource.com/chromium/src/)
and [Flutter engine](https://github.com/flutter/engine).

## Other mapped derivations

The MIT option is used for each entry below. The following copyright notices
and the full permission and disclaimer text in [LICENSE-MIT](LICENSE-MIT)
apply to the respective derived portions; keep both with copies.

| Upstream path | Origin and copyright notice | Original terms | Port area |
|---|---|---|---|
| AccessKit `accesskit/src/geometry.rs` | [kurbo](https://github.com/linebender/kurbo); Copyright 2018 The kurbo Authors | MIT OR Apache-2.0 | `src/schema/geometry/`, `src/capi/geometry.zig` |
| AccessKit `adapters/android/src/inject.rs` | [jni-rs](https://github.com/jni-rs/jni-rs); Copyright 2016 Prevoty, Inc. and jni-rs contributors | MIT OR Apache-2.0 | `src/adapters/android/` |
| AccessKit `adapters/unix/src/executor.rs` | [zbus](https://github.com/dbus2/zbus); Copyright 2024 Zeeshan Ali Khan | MIT | `src/adapters/atspi/` |
| AccessKit C `src/lib.rs` | [rustls-ffi](https://github.com/rustls/rustls-ffi); Copyright (c) 2021, Jacob Hoffman-Andrews <jsha@letsencrypt.org> | Apache-2.0 OR ISC OR MIT | `src/capi/` |

No ISC text is needed for the selected MIT option of the rustls-ffi derivation.

## Distribution

Source and binary distributions containing the header or derived code must
carry `LICENSE`, `LICENSE-MIT`, `LICENSE-APACHE`, `LICENSE.chromium`, this
`NOTICE.md`, and `THIRD_PARTY_NOTICES.md`. The latter includes dependency
notices and MIT terms for bundled dependency code. Keep any additional
copyright notices shipped with the actual dependency version.

No endorsement by AccessKit, Google, Flutter, Apple, Microsoft, or any
contributor is claimed. Native platform SDK terms remain separate.
