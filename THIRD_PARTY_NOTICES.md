# Third-party notices

The MIT grant in `LICENSE` covers the port-authored code and changes. It does
not replace the following third-party grants. [NOTICE.md](NOTICE.md) retains
the exact upstream per-file derivation inventory and copyright years.

| Component | Repository paths or dependency | License | Copyright holder | Upstream |
|---|---|---|---|---|
| AccessKit 0.25.1 | `src/schema/`, `src/consumer/`, `src/adapters/` | MIT OR Apache-2.0; `licenses/LICENSE-MIT`, `licenses/LICENSE-APACHE` | The AccessKit Authors | https://github.com/AccessKit/accesskit/tree/466e24e252103f4d82bd6fbab98141b551e46e0c |
| AccessKit C 0.23.1 | `src/capi/`, `include/zaccesskit.h` | MIT OR Apache-2.0; `licenses/LICENSE-MIT`, `licenses/LICENSE-APACHE` | The AccessKit Authors | https://github.com/AccessKit/accesskit-c/tree/8b6ed37c20ed4c59390e253407983333053662ba |
| Chromium derivations | Schema, consumer, platform adapters, C header; exact upstream files in `NOTICE.md` | BSD-3-Clause; `licenses/LICENSE.chromium` | The Chromium Authors (2015, 2017, 2018, 2021) | https://chromium.googlesource.com/chromium/src/ |
| Flutter engine derivations | `src/adapters/android/`, `src/adapters/ios/`; exact upstream files in `NOTICE.md` | BSD-3-Clause; `licenses/LICENSE.chromium` as specified by upstream headers | The Flutter Authors (2013) | https://github.com/flutter/engine |
| kurbo derivation | `src/schema/geometry/`, `src/capi/geometry.zig` | MIT OR Apache-2.0; MIT option used, `licenses/LICENSE-MIT` | The kurbo Authors (2018) | https://github.com/linebender/kurbo |
| jni-rs derivation | `src/adapters/android/` | MIT OR Apache-2.0; MIT option used, `licenses/LICENSE-MIT` | Prevoty, Inc. and jni-rs contributors (2016) | https://github.com/jni-rs/jni-rs |
| zbus derivation | `src/adapters/atspi/` | MIT; `licenses/LICENSE-MIT` | Zeeshan Ali Khan (2024) | https://github.com/dbus2/zbus |
| rustls-ffi derivation | `src/capi/` | Apache-2.0 OR ISC OR MIT; MIT option used, `licenses/LICENSE-MIT` | Jacob Hoffman-Andrews (2021) | https://github.com/rustls/rustls-ffi |
| zio | Non-vendored `zio` dependency in `build.zig.zon` | MIT; full notices below | Lukas Lalinsky (2025); Zig contributors | https://github.com/lalinsky/zio/tree/9b49086c72edbfbcef00acb557d6177bcaee1cb5 |
| zigwin32 | Non-vendored `win32` dependency in `build.zig.zon` | MIT; dependency `LICENSE`, terms below | Jonathan Marler (2021) | https://github.com/marlersoft/zigwin32/tree/fb2645891520f3e99931db17a7eba04057e87e89 |

## zio

The pinned package excludes its license file. The complete upstream notices
are retained here so distributions bundling zio code can carry them.
Source: https://github.com/lalinsky/zio/blob/9b49086c72edbfbcef00acb557d6177bcaee1cb5/LICENSE

Copyright (c) 2025 Lukas Lalinsky

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

This project includes code from the Zig standard library:

Copyright (c) Zig contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## zigwin32

Source: https://github.com/marlersoft/zigwin32/blob/fb2645891520f3e99931db17a7eba04057e87e89/LICENSE

Copyright 2021 Jonathan Marler

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
