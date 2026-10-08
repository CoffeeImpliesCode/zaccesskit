# 21 — Licensing inventory for the zaccesskit port

Consumed by `docs/30-port-design.md`, which fixes the licence posture of the port,
and by `docs/50-verification.md`, which turns section 6 into a gate.

Evidence convention. Every factual claim below carries its source: `path:line`
for code and licence text, or the exact command plus its output for everything
else. Anything not read directly is marked `[INFERENCE]`. Tree names are
abbreviated after the first use:

| Short name | Full path | Commit | Version |
|---|---|---|---|
| `AK` | `/tmp/scratch/accesskit` | `466e24e252103f4d82bd6fbab98141b551e46e0c` | 0.25.1 |
| `AKC` | `/tmp/scratch/accesskit-c` | `8b6ed37c20ed4c59390e253407983333053662ba` | 0.23.1 |
| `GOOSE` | `/tmp/scratch/goose` | `8c6ee3a984a3b314bb921e3f8f6428a51a6d93e1`, tag `v3.3.0` | 3.3.0 |
| `ZIO` | `~/zio` | pinned `2662fdc45997611b962b560c513c16963475a01b` | 0.18.0 |
| `ZIG` | `/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ` | Zig 0.16.0 release | 0.16.0 |
| `ZAK` | `~/zaccesskit` | working copy | 0.0.0 |

## 1. Scope note

This document is a licence inventory, not legal advice. A qualified reviewer
must confirm every conclusion in it, and must confirm the derivative-work
judgements in section 5, before the port is released.

## 2. Upstream AccessKit licences

### 2.1 The files

A `find` over both trees for `LICENSE*`, `COPYING*`, `AUTHORS` and `NOTICE*`
returned exactly nine files:

```
$ find /tmp/scratch/accesskit /tmp/scratch/accesskit-c \
    -maxdepth 3 \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'AUTHORS' -o -iname 'NOTICE*' \)
/tmp/scratch/accesskit-c/AUTHORS
/tmp/scratch/accesskit-c/COPYING.LIB
/tmp/scratch/accesskit-c/LICENSE-APACHE
/tmp/scratch/accesskit-c/LICENSE-MIT
/tmp/scratch/accesskit-c/LICENSE.chromium
/tmp/scratch/accesskit/AUTHORS
/tmp/scratch/accesskit/LICENSE-APACHE
/tmp/scratch/accesskit/LICENSE-MIT
/tmp/scratch/accesskit/LICENSE.chromium
```

Neither tree has a `NOTICE` file. Neither tree has a `PATENTS` file.

| File | Lines | SPDX identifier | What it covers |
|---|---|---|---|
| `AK/LICENSE-APACHE` | 176 | `Apache-2.0` | The AccessKit-authored material |
| `AK/LICENSE-MIT` | 23 | `MIT` | The AccessKit-authored material |
| `AK/LICENSE.chromium` | 27 | `BSD-3-Clause` | 12 named source files, see section 3 |
| `AKC/COPYING.LIB` | 502 | `LGPL-2.1-only` | The Meson build system only, see 2.5 |
| `AK/AUTHORS` | 9 | none | Copyright holders |
| `AKC/AUTHORS` | 8 | none | Copyright holders |

The three shared files are byte-identical between the two repositories. The
command `diff` reported no difference for each of `LICENSE-APACHE`,
`LICENSE-MIT` and `LICENSE.chromium`.

The two trees agree on the headline grant. `AK/Cargo.toml:25` reads
`license = "MIT OR Apache-2.0"`, and `AKC/Cargo.toml:14` reads the same.

`AK/README.md:76-82` states it in prose:

> AccessKit is licensed under the [Apache License, Version 2.0](LICENSE-APACHE)
> or the [MIT license](LICENSE-MIT), at your option.
>
> Unless you explicitly state otherwise, any contribution intentionally
> submitted for inclusion in AccessKit by you, as defined in the Apache License,
> shall be dual-licensed as above, without any additional terms or conditions.
>
> The list of authors for copyright purposes is in the [AUTHORS](AUTHORS) file.
>
> Significant portions of AccessKit are derived from Chromium and are covered
> by its [BSD-style license](LICENSE.chromium).

`AKC/README.md:108-116` repeats the first three paragraphs and adds a fourth:

> The Meson build system for accesskit-c is licensed under the [GNU Lesser
> General Public License, Version 2.1](COPYING.LIB). Note that this license
> applies only to the build system, not to the accesskit-c library itself.

### 2.2 Apache-2.0

`AK/LICENSE-APACHE` is 176 lines and holds the Apache License 2.0 terms of use.
The file ends at line 176 with `END OF TERMS AND CONDITIONS`. It has **no
appendix**. A grep for `APPENDIX` and for `Copyright [yyyy]` in that file
returned no match. The usual boilerplate template is therefore absent from this
copy.

Operative clauses:

* Grant of copyright licence, `AK/LICENSE-APACHE:66-71`:

  > 2. Grant of Copyright License. Subject to the terms and conditions of this
  > License, each Contributor hereby grants to You a perpetual, worldwide,
  > non-exclusive, no-charge, royalty-free, irrevocable copyright license to
  > reproduce, prepare Derivative Works of, publicly display, publicly perform,
  > sublicense, and distribute the Work and such Derivative Works in Source or
  > Object form.

* Grant of patent licence, `AK/LICENSE-APACHE:73-87`. The termination clause at
  `:82-87` reads:

  > If You institute patent litigation against any entity (including a
  > cross-claim or counterclaim in a lawsuit) alleging that the Work or a
  > Contribution incorporated within the Work constitutes direct or contributory
  > patent infringement, then any patent licenses granted to You under this
  > License for that Work shall terminate as of the date such litigation is
  > filed.

* Redistribution conditions, `AK/LICENSE-APACHE:89-128`. All four sub-clauses
  bind the port:

  > (a) You must give any other recipients of the Work or Derivative Works a
  > copy of this License; and
  >
  > (b) You must cause any modified files to carry prominent notices stating
  > that You changed the files; and
  >
  > (c) You must retain, in the Source form of any Derivative Works that You
  > distribute, all copyright, patent, trademark, and attribution notices from
  > the Source form of the Work, excluding those notices that do not pertain to
  > any part of the Derivative Works; and
  >
  > (d) If the Work includes a "NOTICE" text file as part of its distribution,
  > then any Derivative Works that You distribute must include a readable copy
  > of the attribution notices contained within such NOTICE file [...]

* Additional-grant permission, `AK/LICENSE-APACHE:123-128`:

  > You may add Your own copyright statement to Your modifications and may
  > provide additional or different license terms and conditions for use,
  > reproduction, or distribution of Your modifications, or for any such
  > Derivative Works as a whole, provided Your use, reproduction, and
  > distribution of the Work otherwise complies with the conditions stated in
  > this License.

* `AK/LICENSE-APACHE:40-47` defines "Derivative Works" broadly:

  > "Derivative Works" shall mean any work, whether in Source or Object form,
  > that is based upon the Work or upon modifications thereof, and that,
  > [taken] intentionally [...] is based upon the Work or upon modifications
  > thereof.

  `[INFERENCE]` A translation from Rust to Zig is "based upon" the Rust within
  the plain meaning of this definition. This is a reading of the text, not a
  legal conclusion.

### 2.3 MIT

`AK/LICENSE-MIT` is 23 lines. Line 1 is `Permission is hereby granted`. The file
carries **no copyright line at all**. The grant, `AK/LICENSE-MIT:1-9`:

> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:

The only condition, `AK/LICENSE-MIT:11-13`:

> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.

The disclaimer follows at `AK/LICENSE-MIT:15-23`.

The MIT file names no copyright holder. The copyright notice for this arm lives
in the per-file headers. Every AccessKit-authored source file starts with
`AK/accesskit/src/geometry.rs:1-4`:

```
// Copyright 2023 The AccessKit Authors. All rights reserved.
// Licensed under the Apache License, Version 2.0 (found in
// the LICENSE-APACHE file) or the MIT license (found in
// the LICENSE-MIT file), at your option.
```

### 2.4 The Chromium BSD-3-Clause

See section 3 for the full treatment.

### 2.5 LGPL-2.1, accesskit-c Meson build only

`AKC/COPYING.LIB` is 502 lines. `AKC/COPYING.LIB:1-2` names it:

> GNU LESSER GENERAL PUBLIC LICENSE
> Version 2.1, February 1999

Applicability, `AKC/COPYING.LIB:118-121`:

> 0. This License Agreement applies to any software library or other program
> which contains a notice placed by the copyright holder or other authorized
> party saying it may be distributed under the terms of this Lesser General
> Public License (also called "this License").

The FSF notice obligations, `AKC/COPYING.LIB:152-156`:

> you conspicuously and appropriately publish on each copy an appropriate
> copyright notice and disclaimer of warranty; keep intact all the notices that
> refer to this License and to the absence of any warranty; and distribute a
> copy of this License along with the Library.

The scope is narrow and self-declared. `AKC/README.md:116` says the licence
"applies only to the build system, not to the accesskit-c library itself". The
files carrying the L. E. Segovia header are `AKC/meson.build:2-5`,
`AKC/meson_options.txt:2-5`, `AKC/meson/cargo_wrapper.py:3-6`,
`AKC/meson/check-is-version-string.py:3-6`,
`AKC/meson/project_version.py:3-6` and `AKC/meson/query-rustc.py:3-6`.
`AKC/meson/makedef.py:2-4` carries a different header:

> Copyright (c) 2022 L. E. Segovia <amy@amyspark.me>
>
> This file is part of the FFmpeg Meson build

`[INFERENCE]` The Meson build is the only LGPL-2.1 material in either tree. The
port does not use Meson, so it has no reason to copy any of those files. If it
copies one anyway, it acquires an LGPL-2.1 obligation for the copy. Section 8
records this as a do-not-copy rule.

### 2.6 One tree, several arms: what triple licensing means here

The tree is **not** triple licensed in the SPDX sense. There is no
`MIT OR Apache-2.0 OR BSD-3-Clause` anywhere, and neither README states such an
expression.

| Material | SPDX expression, read from the tree | Evidence |
|---|---|---|
| AccessKit-authored files | `MIT OR Apache-2.0` | `AK/Cargo.toml:25`, `AKC/Cargo.toml:14` |
| `adapters/winit/**` | `Apache-2.0` | `AK/adapters/winit/Cargo.toml:5`, `AK/adapters/winit/src/lib.rs:1-3` |
| 12 files derived from Chromium or the Flutter engine | `BSD-3-Clause` | `AK/LICENSE.chromium:1-15`, see section 3 |
| `AK/accesskit/src/geometry.rs` | `MIT OR Apache-2.0`, kurbo's choice | `AK/accesskit/src/geometry.rs:6-10` |
| `AK/adapters/android/src/inject.rs` | `MIT OR Apache-2.0`, jni-rs's choice | `AK/adapters/android/src/inject.rs:6-10` |
| `AK/adapters/unix/src/executor.rs` | `MIT`, zbus's choice | `AK/adapters/unix/src/executor.rs:6-8` |
| `AKC/src/lib.rs` | `Apache-2.0 OR ISC OR MIT`, rustls-ffi's choice | `AKC/src/lib.rs:6-11` |
| `AKC/meson/**` | `LGPL-2.1-only` | `AKC/README.md:116` |

Two consequences follow, and both bind the port.

First, the Chromium material is **not** covered by either arm of the headline
choice. `AK/README.md:82` puts it in a separate sentence, outside the "at your
option" paragraph at `:76`. `[INFERENCE]` The correct expression for a port that
translates Chromium-derived files is `(MIT OR Apache-2.0) AND BSD-3-Clause`,
because the BSD-3-Clause conditions attach to those files whatever the
downstream picks for the rest. Section 8 marks this for legal review.

Second, `AK/adapters/winit/**` is Apache-2.0 only. The MIT arm is not available
for the winit adapter, so a translated winit adapter must carry Apache-2.0
obligations only. `AK/adapters/winit/Cargo.toml:5` reads
`license = "Apache-2.0"`, and every winit source file header ends at line 3 with
`// Licensed under the Apache License, Version 2.0.` with no "or the MIT
license" clause. `[INFERENCE]` The port philosophy has no winit analogue, so
this probably does not arise. It is recorded so the reader does not assume the
MIT arm is universal.

### 2.7 Copyright holders

`AK/AUTHORS:6-9` lists:

```
Matt Campbell
Arnold Loubriat
Google LLC
Leonard de Ruijter
```

`AKC/AUTHORS:6-8` lists:

```
Arnold Loubriat
Matt Campbell
Leonard de Ruijter
```

Both files carry the same caveat, `AK/AUTHORS:1-5`:

> This is the list of AccessKit authors for copyright purposes.
>
> This does not necessarily list everyone who has contributed code, since in
> some cases, their employer may be the copyright holder. To see the full list
> of contributors, see the revision history in source control.

`[INFERENCE]` The AUTHORS file is not a grant and not a notice obligation under
any of the four licences. The port cites it as provenance, not as a condition.

### 2.8 Upstream's own dependency licence policy

`AK/deny.toml:299-314` and `AKC/deny.toml:362-377` are identical. Both allow
only `Apache-2.0`, `Apache-2.0 WITH LLVM-exception`, `BSD-2-Clause`,
`BSD-3-Clause`, `ISC`, `MIT` and `Zlib`, at `confidence-threshold = 0.8`, with
one named exception for `unicode-ident`. `[INFERENCE]` This tells the reader which
licence vocabulary upstream considers in scope. It has no effect on the port.

## 3. The Chromium licence

### 3.1 The text

`AK/LICENSE.chromium` is 27 lines. It is the 3-clause BSD form that Google uses
across Chromium. Line 1 names the holder:

> // Copyright 2015 The Chromium Authors. All rights reserved.

The grant, `AK/LICENSE.chromium:3-4`:

> // Redistribution and use in source and binary forms, with or without
> // modification, are permitted provided that the following conditions are
> // met:

The three conditions, `AK/LICENSE.chromium:7-15`. These are the obligations:

> //    * Redistributions of source code must retain the above copyright
> // notice, this list of conditions and the following disclaimer.
> //    * Redistributions in binary form must reproduce the above
> // copyright notice, this list of conditions and the following disclaimer
> // in the documentation and/or other materials provided with the
> // distribution.
> //    * Neither the name of Google Inc. nor the names of its
> // contributors may be used to endorse or promote products derived from
> // this software without specific prior written permission.

SPDX identifier: `BSD-3-Clause`. `[INFERENCE]` That identifier is not written in
the file. Neither tree's own source carries an `SPDX-License-Identifier` line.
The only two SPDX lines in either tree sit in third-party Gradle wrapper
scripts, `AK/adapters/android/examples/hello_world_app/gradlew:18` and
`gradlew.bat:16`, both reading `# SPDX-License-Identifier: Apache-2.0`. The
mapping from the three conditions to `BSD-3-Clause` is a naming convention, so
it is recorded as an inference rather than a reading.

### 3.2 What it covers: the twelve files

The licence file names no path. Scope is established only by per-file headers,
and each header points back at the licence file. A grep for the pointer string
`LICENSE.chromium file` over `*.rs` and `*.java` returned exactly twelve hits,
all at line 9:

```
$ grep -rn 'LICENSE\.chromium file' --include='*.rs' --include='*.java' /tmp/scratch/accesskit
.../accesskit/src/lib.rs:9
.../adapters/macos/src/node.rs:9
.../adapters/android/src/node.rs:9
.../adapters/android/src/event.rs:9
.../adapters/android/src/adapter.rs:9
.../adapters/atspi-common/src/node.rs:9
.../adapters/atspi-common/src/adapter.rs:9
.../adapters/ios/src/node.rs:9
.../adapters/ios/src/adapter.rs:9
.../adapters/windows/src/node.rs:9
.../accesskit_consumer/src/iterators.rs:9
.../accesskit_consumer/src/node.rs:9
```

The twelve split by the holder named at line 7. Eight name The Chromium
Authors, four name The Flutter Authors.

| # | File | Line 6 | Line 7 | Year |
|---|---|---|---|---|
| 1 | `AK/accesskit/src/lib.rs` | `Derived from Chromium's accessibility abstraction.` | `Copyright 2018 The Chromium Authors. All rights reserved.` | 2018 |
| 2 | `AK/accesskit_consumer/src/iterators.rs` | same | `Copyright 2018 The Chromium Authors. All rights reserved.` | 2018 |
| 3 | `AK/accesskit_consumer/src/node.rs` | same | `Copyright 2021 The Chromium Authors. All rights reserved.` | 2021 |
| 4 | `AK/adapters/atspi-common/src/adapter.rs` | same | `Copyright 2017 The Chromium Authors. All rights reserved.` | 2017 |
| 5 | `AK/adapters/atspi-common/src/node.rs` | same | `Copyright 2017 The Chromium Authors. All rights reserved.` | 2017 |
| 6 | `AK/adapters/android/src/node.rs` | same | `Copyright 2018 The Chromium Authors. All rights reserved.` | 2018 |
| 7 | `AK/adapters/macos/src/node.rs` | same | `Copyright 2018 The Chromium Authors. All rights reserved.` | 2018 |
| 8 | `AK/adapters/windows/src/node.rs` | same | `Copyright 2021 The Chromium Authors. All rights reserved.` | 2021 |
| 9 | `AK/adapters/android/src/adapter.rs` | `Derived from the Flutter engine.` | `Copyright 2013 The Flutter Authors. All rights reserved.` | 2013 |
| 10 | `AK/adapters/android/src/event.rs` | `Derived from the Flutter engine.` | `Copyright 2013 The Flutter Authors. All rights reserved.` | 2013 |
| 11 | `AK/adapters/ios/src/adapter.rs` | `Derived from the Flutter engine.` | `Copyright 2013 The Flutter Authors. All rights reserved.` | 2013 |
| 12 | `AK/adapters/ios/src/node.rs` | `Derived from the Flutter engine.` | `Copyright 2013 The Flutter Authors. All rights reserved.` | 2013 |

All twelve also carry the AccessKit Authors block at lines 1-4. So each of the
twelve is dual-noticed: `MIT OR Apache-2.0` from AccessKit at the top, and
`BSD-3-Clause` from Chromium or Flutter below it. `AK/accesskit/src/lib.rs:1-9`
is the full shape:

```
// Copyright 2021 The AccessKit Authors. All rights reserved.
// Licensed under the Apache License, Version 2.0 (found in
// the LICENSE-APACHE file) or the MIT license (found in
// the LICENSE-MIT file), at your option.

// Derived from Chromium's accessibility abstraction.
// Copyright 2018 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE.chromium file.
```

### 3.3 The four Flutter files

Rows 9 to 12 name The Flutter Authors, not The Chromium Authors. They point at
`LICENSE.chromium` anyway. `[INFERENCE]` AccessKit treats the Flutter engine's
notice as covered by the same BSD-style text. That is a reasonable reading,
because the Flutter engine ships the same three-clause BSD grant. A reviewer
should still confirm that no Flutter-specific wording is lost.

### 3.4 What `git log` establishes, and what it does not

The licence file has exactly one commit in its history:

```
$ git -C /tmp/scratch/accesskit log --follow --format='%h|%ad|%s' --date=short -- LICENSE.chromium
9ed5679|2021-06-26|Add the Chromium license
```

The full hash is `9ed56791fe0826c1d00956ddecca751236c0482a`, authored by Matt
Campbell on 2021-06-26. `git show --stat` on that commit reports:

```
LICENSE.chromium | 27 +++++++++++++++++++++++++++
1 file changed, 27 insertions(+)
```

So `LICENSE.chromium` was added in one commit and never changed since. It
never listed a path, so its own history cannot define its scope. The twelve
headers are the only scope record.

A walk for commits that introduced the pointer line is **incomplete**:

```
$ git -C /tmp/scratch/accesskit log -S'LICENSE.chromium file' -- '*.rs'
2dbb06f|2026-05-11|feat: Basic iOS adapter (#710)
7ac5911|2025-05-04|refactor!: Simplify the core Android adapter API (#558)
Schwerwiegend: Sie versuchen 466e24e2... zu holen, welches sich in der Commit-Graph-Datei,
aber nicht in der Objektdatenbank befindet.
Schwerwiegend: konnte be68aefaf6bada816b1213049fce9d0bb548dcd0 nicht von Promisor-Remote abrufen
```

`AK` is a partial clone. Object `be68aefaf6bada816b1213049fce9d0bb548dcd0`
is in the commit graph but not in the object database. The walk stops there.
The two commits it did return are consistent with the header set: one added the
iOS adapter files in rows 11 and 12, the other rewrote the Android adapter.

**Evidence quality.** The header set is `SOURCE-CONFIRMED`, read off the
working tree at the pinned commit. The claim that those headers are the
complete and only scope of the licence is `SOURCE-CONFIRMED` as a reading of
upstream's own record, and it is **not** verified against a Chromium checkout.
A reviewer who wants certainty would diff the AccessKit role lists against the
Chromium `ui/accessibility` tree at the matching dates.

### 3.5 Other third-party headers in the same trees

Four further files carry a derivation header outside the Chromium set. None
introduces a licence the port does not already plan to carry.

| File | Line 6 | Line 7 | Lines 8 to 10 | SPDX expression |
|---|---|---|---|---|
| `AK/accesskit/src/geometry.rs` | `Derived from kurbo.` | `Copyright 2018 The kurbo Authors.` | Apache-2.0 or MIT | `MIT OR Apache-2.0` |
| `AK/adapters/android/src/inject.rs` | `Derived from jni-rs` | `Copyright 2016 Prevoty, Inc. and jni-rs contributors` | Apache-2.0 or MIT | `MIT OR Apache-2.0` |
| `AK/adapters/unix/src/executor.rs` | `Derived from zbus.` | `Copyright 2024 Zeeshan Ali Khan.` | MIT only | `MIT` |
| `AKC/src/lib.rs` | `Derived from rustls-ffi.` | `Copyright (c) 2021, Jacob Hoffman-Andrews <jsha@letsencrypt.org>` | Apache-2.0, ISC, or MIT, at lines 8 to 11 | `Apache-2.0 OR ISC OR MIT` |

`AK/adapters/winit/src/platform_impl/mod.rs:5` carries a bare sentence with no
copyright block:

> // Based loosely on winit's src/platform_impl/mod.rs.

`[INFERENCE]` "Based loosely on" is below the threshold of copying, so no
obligation is read from it. A reviewer decides.

`AKC/src/lib.rs:10` names `the LICENSE-ISC file`. **No `LICENSE-ISC` file exists
in `AKC`.** The `find` in 2.1 returned no such file. `[INFERENCE]` This is an
upstream defect in attribution: the header points at a file that was never
shipped. A port that translates this file must not copy the broken pointer. See
action item A9 in section 8.

### 3.6 The generated C header loses the Chromium notice

`AKC/include/accesskit.h` is 3154 lines. Its first lines, `AKC/include/accesskit.h:1-6`:

```
/**
 * Copyright 2023 The AccessKit Authors. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (found in
 * the LICENSE-APACHE file) or the MIT license (found in
 * the LICENSE-MIT file), at your option.
 */
```

That block is generated. `AKC/cbindgen.toml:2-7` holds the same text as the
cbindgen `header` template. cbindgen copies the Rust doc comments across, so
Chromium-referencing prose survives. For example `AKC/include/accesskit.h:272-273`:

>  * Like the AccessKit schema as a whole, this list is largely taken
>  * from Chromium. However, unlike Chromium's alphabetized list, this list

and `AKC/include/accesskit.h:471-475`:

>   /**
>    * Behaves similar to an ARIA grid but is primarily used by Chromium's
>    * `TableView` and its subclasses, so they can be exposed correctly
>    * on certain platforms.
>    */

No Chromium or Flutter copyright line appears anywhere in `accesskit.h`. A grep
for `The Chromium Authors` and for `Chromium Authors` across the whole `AKC`
tree returned `AKC/LICENSE.chromium:1` only. `[INFERENCE]` The header embeds
material from `AK/accesskit/src/lib.rs`, which is a BSD-3-Clause file, so the
generated header carries BSD-3-Clause-derived content without the
BSD-3-Clause notice. That is a real gap in upstream, not a matter of taste. A
port that reproduces any of this prose in its own C header must carry the
Chromium notice. See action item A10.

### 3.7 What a derived work carries

The port satisfies BSD-3-Clause by doing all of the following, for every
translated file that corresponds to one of rows 1 to 12:

1. Retain the Chromium or Flutter copyright line verbatim, with its year.
2. Retain the three conditions, by shipping `LICENSE.chromium` unedited.
3. Retain the disclaimer, in the same `LICENSE.chromium` file.
4. Ship that file with any binary distribution, in the documentation or other
   materials.
5. Never use the name "Google Inc." or the names of its contributors to endorse
   or promote the port.

Point 5 is the one that constrains writing, not packaging. The port README, the
package description and the release notes must not describe the port as
"officially from Google", "endorsed by Chrome", or any similar claim. Naming
the upstream project in order to state where the port came from is a different
act. `[INFERENCE]` A qualified reviewer draws that line. Section 8 marks it as a
legal decision.

## 4. Per dependency licences

One row per dependency the port keeps. "Compatible" means the obligation can be
met by shipping the port in source and in binary form, with the notice and the
licence text in the distribution. It is a compatibility reading, not a legal
opinion.

| Name | Licence | SPDX identifier | Read at | Compatible with shipping the port |
|---|---|---|---|---|
| AccessKit core, 0.25.1 | Apache-2.0 or MIT, plus BSD-3-Clause on 12 files | `MIT OR Apache-2.0` per file; `BSD-3-Clause` on the twelve | `AK/Cargo.toml:25`, `AK/LICENSE.chromium:1-15` | Yes, if every obligation in section 6 is met |
| AccessKit C bindings, 0.23.1 | same, plus LGPL-2.1 on the Meson build only | same | `AKC/Cargo.toml:14`, `AKC/README.md:116` | Yes, if the Meson build is not copied |
| `AKC/src/lib.rs` derivation, rustls-ffi | Apache-2.0, ISC, or MIT | `Apache-2.0 OR ISC OR MIT` | `AKC/src/lib.rs:6-11` | Yes. The `LICENSE-ISC` pointer is broken upstream, see 3.5 |
| kurbo | Apache-2.0 or MIT | `MIT OR Apache-2.0` | `AK/accesskit/src/geometry.rs:6-10` | Yes. Same arms the port already carries |
| jni-rs | Apache-2.0 or MIT | `MIT OR Apache-2.0` | `AK/adapters/android/src/inject.rs:6-10` | Yes. Same arms |
| zbus | MIT | `MIT` | `AK/adapters/unix/src/executor.rs:6-8` | Yes. The port replaces zbus with goose, so the port keeps the port, not the code |
| goose, 3.3.0 | MIT | `MIT` | `GOOSE/LICENSE:1-19` | Yes. See the packaging note below |
| zio, 0.18.0 | MIT, plus MIT for Zig standard library code | `MIT` | `ZIO/LICENSE:1-19` and `ZIO/LICENSE:23-43` | Yes. See the packaging note below |
| Zig standard library | MIT "Expat" | `MIT` | `ZIG/LICENSE:1-21` | Yes. Reaches the port only through zio |

### 4.1 goose

`GOOSE/LICENSE:1` reads:

> Copyright (c) 2025 luxluth <delphin.blehoussi93@gmail.com>

The file is 19 lines of standard MIT text and carries no other grant. It was
present in the repository's first commit, `git log --diff-filter=A -- LICENSE`
returning `55ae1e5|2025-01-12|initial commit`. `GOOSE/README.md:220-222` reads:

> ## License
>
> This project is licensed under the MIT License - see the [LICENSE](LICENSE)
> file for details.

**Packaging note.** `GOOSE/build.zig.zon:10-16` lists `"LICENSE"` in `.paths`.
A downstream that fetches goose therefore receives the licence text inside the
package. The port still has to cite it, because a MIT recipient of a compiled
binary never receives the source package.

**Source headers.** A grep for `SPDX` across `GOOSE/src` returned no match.
`GOOSE/src/root.zig:1` starts at `const std = @import("std");`. There is no
per-file attribution to retain. The MIT notice in `GOOSE/LICENSE` is the whole
record.

### 4.2 zio

`ZIO/LICENSE` is 43 lines and holds **two** MIT blocks. The first,
`ZIO/LICENSE:1-19`:

> Copyright (c) 2025 Lukas Lalinsky

The second, introduced at `ZIO/LICENSE:21-23`:

> ---
>
> This project includes code from the Zig standard library:
>
> Copyright (c) Zig contributors

`ZIO/README.md:199-201` and `ZIO/docs/index.md:59-61` both say only:

> ## License
>
> This project is licensed under the [MIT license].

So the README names one licence and the file holds two grants. The house rule
against reducing a tree to one label applies here. See
`foundation-libs/AGENTS.md:227-228` in section 7.

The second block is real, not boilerplate. `ZIO/src/fs.zig:1-3` reads:

```
// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-FileCopyrightText: Zig contributors (deleteTree, ported from std.Io.Dir)
// SPDX-License-Identifier: MIT
```

**Packaging note, and this one matters.** `ZIO/build.zig.zon:6-11` lists only:

```
.paths = .{
    "build.zig",
    "build.zig.zon",
    "src",
    "examples",
},
```

`LICENSE` is **not** in `.paths`. `[INFERENCE]` A downstream that fetches zio
from the package manager receives no licence file. The port is therefore the
only place where the MIT notice for zio can travel. It must copy the text. See
action item A6.

**The fetch URL is the upstream author, not a fork.** `ZAK/build.zig.zon:30` reads:

> .url = "https://codeload.github.com/lalinsky/zio/tar.gz/2662fdc45997611b962b560c513c16963475a01b",

and the comment at `ZAK/build.zig.zon:23-28` says why:

> Fetched from `lalinsky/zio`, the upstream author, not from a fork account. The same
> commit is reachable from both, and the contents are identical, so the choice costs
> nothing and keeps the pin auditable against the account that owns the project.

The licence reason behind that choice still stands. A fork URL carries no asserted
licence of its own. `ZIO/LICENSE` covers the upstream author's commits, and a fork
account can add commits whose grant nobody has asserted. Pinning the upstream account
puts every fetched byte under a grant the port can cite. The pin is exact, so the
tarball is reproducible.

### 4.3 Zig standard library

`ZIG/LICENSE:1-21` is the MIT Expat text:

> The MIT License (Expat)
>
> Copyright (c) Zig contributors

`ZIO/LICENSE:23-43` is a byte-equivalent reproduction of the same grant under
the heading "This project includes code from the Zig standard library". The
port takes zio as a package dependency and never copies zio source, so the Zig
standard library grant reaches the port only through zio's own notice. If the
port ever vendors a Zig standard library file, that file's grant applies and
the port must carry `ZIG/LICENSE`.

### 4.4 C libraries: none pinned

No C library is pinned. `local://zaccesskit-deps.md` names exactly two dependencies,
goose and zio, and rejects `libdbus` in favour of a Zig implementation.
`ZAK/build.zig.zon:12-34` declares exactly one dependency, `.zio`. That is the
observable state on 2026-10-05.

For the record, this host offers these C development packages:

```
$ for m in dbus-1 atspi-2 glib-2.0 gio-2.0 gobject-2.0 libxcb xcb wayland-client freetype2 harfbuzz fontconfig libudev; do
      printf '%-16s ' "$m"; pkg-config --modversion "$m" 2>/dev/null || echo '(absent)'; done
dbus-1           1.14.10
atspi-2          (absent)
glib-2.0         2.84.4
gio-2.0          2.84.4
gobject-2.0      2.84.4
libxcb           (absent)
xcb              1.17.0
wayland-client   1.24.0
freetype2        (absent)
harfbuzz         (absent)
fontconfig       (absent)
libudev          257
```

**No SPDX identifier is recorded for any of these.** This document did not read
a licence file for any of them, so it asserts none. `[INFERENCE]` The presence
of a package on a build host says nothing about whether the port will link it.
`docs/22-zig-build-surface.md` names the `translate-c` bindings, if any, and
this table gains a row at that point.

**Platform SDKs are a separate matter.** The macOS adapter binds NSAccessibility
and the iOS adapter binds UIAccessibility. The Windows adapter binds UI
Automation through COM. These are platform SDK surfaces, not redistributable
libraries, and their terms are set by the vendor agreement for the SDK, not by
a licence file. This host has no Apple SDK and no Windows SDK, so this document
cannot read those terms and does not record them. `[INFERENCE]` Marking this for
a reviewer is in section 8.

## 5. What a direct port may reuse

Five categories. For each, the question is whether a translated Zig file
derived from the material is a derivative work, and what attribution the
licence requires.

The word "derivative work" is a copyright-law term, not a licence term, except
where a licence defines it. Apache-2.0 defines it at `AK/LICENSE-APACHE:40-47`.
For the other three licences the test is whatever the applicable jurisdiction
applies. `[INFERENCE]` throughout this section marks that step.

| Category | Is a translated Zig file a derivative work? | Attribution the licence requires |
|---|---|---|
| Upstream Rust source | Almost certainly yes | Apache 4(a) copy, 4(b) change notice, 4(c) retain notices; MIT notice retention; BSD-3-Clause source retention |
| Upstream documentation | Depends, see 5.2 | Retain the copyright and permission notices that travel with it |
| Upstream comments and doc comments | Almost certainly yes, see 5.3 | Same as source, per Apache 4(c) |
| The C header | Almost certainly yes, see 5.4 | Apache 4(a) to 4(c), plus the BSD-3-Clause notice that upstream dropped |
| The example programs | Almost certainly yes, see 5.5 | Same as source |

### 5.1 Upstream Rust source

`[INFERENCE]` A file-by-file translation keeps the structure, the names, the
ordering and the logic of the original. It is "based upon the Work" within
Apache-2.0's definition at `AK/LICENSE-APACHE:40-47`, and it is a "modified"
copy within MIT's grant at `AK/LICENSE-MIT:5-6`. Jurisdictions differ on where
translation sits, and the stricter reading is the safe one, so the port treats
every translated file as a derivative work of the Rust file it came from.

For the twelve Chromium and Flutter files, the BSD-3-Clause conditions apply on
top. The port must satisfy all of them, and section 3.7 lists them.

**What this means in practice.** Every translated Zig file starts with the same
block structure as the Rust file it came from: the AccessKit notice, then the
derivation notice if one existed, then a line saying the file was translated
and modified. Apache 4(b) demands "prominent notices stating that You changed
the files", and section 6 gives the exact wording to use.

### 5.2 Upstream documentation

Four documents in `AK` and one in `AKC` are candidates: `AK/README.md`,
`AK/ARCHITECTURE.md`, `AK/README-APPLICATION-DEVELOPERS.md`,
`AKC/README.md`, and the crate-level `AK/accesskit/README.md` and
`AK/accesskit_consumer/README.md`. None of the crate-level ones mentions a
licence; a grep for `licen` across the four prose files at the crate level
returned no match.

`[INFERENCE]` Documentation prose is protected, but the idea behind prose is
not. The descriptive statement at `AK/README.md:15` that the schema "is based
largely on Chromium's cross-platform accessibility abstraction" states a fact
and carries little copyrightable expression. `[INFERENCE]` Restating a fact
does not require attribution. Copying sentences does, because the sentences are
expression.

The safe rule for the port, and the rule the house already applies, is to write
its own documentation and cite the upstream README in a provenance section. The
port needs a provenance section anyway. Section 6 item R4 requires it.

One line is worth quoting regardless, because it is a statement about the
port's own rights. `AK/README.md:82`:

> Significant portions of AccessKit are derived from Chromium and are covered
> by its [BSD-style license](LICENSE.chromium).

`[INFERENCE]` The port's README should carry an equivalent sentence, because
the port also translates those files.

### 5.3 Upstream comments and doc comments

`[INFERENCE]` A comment is part of the source file. If the file is a derivative
work, the comment is inside it, and Apache 4(c) requires retention of "all
copyright, patent, trademark, and attribution notices from the Source form of
the Work". A "why" comment that explains a non-obvious decision is also the
part most worth carrying across, because it carries the reasoning that a later
reader needs.

The house rules do not conflict. `ozai/AGENTS.md:184-187`, section 9,
removes comments that restate the code and keeps why-comments. A port comment
that explains why the Zig code is shaped as it is passes both rules.

Two categories deserve separate treatment.

*Doc comments that mention Chromium.* For example `AK/accesskit/src/lib.rs:42-46`
and `:262-265`. `[INFERENCE]` These are AccessKit-authored prose about
Chromium, not Chromium-authored prose, so they are not BSD-3-Clause material.
They may be translated freely under the AccessKit arm. The generated C header
reproduces them at `AKC/include/accesskit.h:272-273` and `:471-475` with no
Chromium notice, which section 3.6 treats as an upstream gap.

*Doc comments carried by cbindgen.* `[INFERENCE]` A doc comment reproduced
mechanically into a generated header is still a reproduction. The port should
write its own doc comments and should not regenerate a header from another
language's source.

### 5.4 The C header

`AKC/include/accesskit.h` is 3154 lines, generated by cbindgen from the Rust
types. `AKC/cbindgen.toml:2-7` supplies the notice block and
`AKC/README.md:82-104` documents the regeneration procedure.

`[INFERENCE]` The header is a derivative work of the Rust types in
`AKC/src/`, which in turn derive from `AK/accesskit/src/lib.rs`, which is
BSD-3-Clause material. Section 3.6 shows that the shipped header carries no
Chromium notice. A port that reproduces any part of this header inherits that
defect.

The port's own design intends to expose a C ABI, and `docs/31-c-abi-design.md`
will define it. `[INFERENCE]` The clean approach is to write the Zig `export`
surface first, then generate or hand-write the header from the Zig source, so
the header is derived from the port and carries the port's notices. That also
keeps the build free of cbindgen, which the port philosophy already requires.

Attribution the port must carry for any header text taken from
`AKC/include/accesskit.h`:

1. The AccessKit Authors notice, `AKC/include/accesskit.h:1-6`.
2. A copy of `LICENSE-APACHE` and a copy of `LICENSE-MIT`, per Apache 4(a).
3. A copy of `LICENSE.chromium`, per BSD-3-Clause conditions 1 and 2, **plus**
   the Chromium and Flutter copyright lines, which upstream omitted.

### 5.5 The example programs

Ten `.rs` and `.java` files in `AK` carry no licence header at all. A grep for
files lacking the AccessKit Authors block returned exactly these:

```
AK/adapters/android/examples/hello_world_app/app/src/main/java/dev/accesskit/helloworld/HelloWorldView.java
AK/adapters/android/examples/hello_world_app/app/src/main/java/dev/accesskit/helloworld/MainActivity.java
AK/adapters/android/examples/hello_world.rs
AK/adapters/windows/examples/hello_world.rs
AK/adapters/winit/examples/mixed_handlers.rs
AK/adapters/winit/examples/simple.rs
AK/adapters/winit/examples/util/mod.rs
AK/example_common/src/key.rs
AK/example_common/src/lib.rs
AK/example_common/src/render.rs
```

The C examples in `AKC` carry no header either. `AKC/examples/sdl/hello_world.c:1`
starts at `#include <SDL.h>`. `AKC/examples/windows/hello_world.c:1` starts at
`#include <stdio.h>`. The Android activity
`AKC/examples/sdl/android/app/src/main/java/dev/accesskit/sdl_example/AccessKitSDLActivity.java`
was not read directly, and is listed here as unverified.

The header count is 89 of 99 `.rs` and `.java` files in `AK`, and 8 of 8 in
`AKC/src`.

`[INFERENCE]` An example with no per-file header is still covered by the
repository's `MIT OR Apache-2.0` grant, because `AK/Cargo.toml:25` states it at
the workspace level and the workspace owns every member. The absent header is a
style inconsistency, not a licence gap. A translated example is a derivative
work and carries the same obligations as any other translated file.

One header differs. `AK/adapters/windows/examples/hello_world.rs:1` reads:

> // Based on the create_window sample in windows-samples-rs.

`[INFERENCE]` That points at Microsoft's sample code without a copyright line.
The port should not translate this example. It has no role in a library.

### 5.6 Where the answer depends on jurisdiction

Three questions in this section are decided by copyright law rather than by the
licence text. They are flagged rather than answered.

1. **Whether a translation is a derivative work.** Every jurisdiction this port
   could ship in has a translation right in the Berne Convention, which the
   United States did not implement as a separate right. `[INFERENCE]` A
   reviewer should treat translation as copying everywhere.
2. **Whether a translated file that shares only names and structure is a
   derivative work.** Names and structure are thin. `[INFERENCE]` The port does
   not rely on this argument. It translates module by module and function by
   function, as the port philosophy requires, so the question does not arise.
3. **Whether a port may use the upstream project's name.** Trademark and
   unfair-competition rules differ, and they are separate from copyright.
   `[INFERENCE]` The port's name is `zaccesskit`. Whether that is acceptable is
   a legal decision, marked in section 8.

## 6. Obligations the port must satisfy

This is an executable checklist. Each item names the file to touch and the text
to put there. An item marked **(legal)** cannot be closed by an engineer.

### 6.1 Is a NOTICE file required?

The answer differs by licence, and the honest answer is "not by these licences,
but ship one anyway".

* **Apache-2.0**: no. `AK/LICENSE-APACHE:106-108` makes the NOTICE obligation
  conditional: "If the Work includes a "NOTICE" text file as part of its
  distribution". Neither `AK` nor `AKC` has a NOTICE file, as the `find` in
  2.1 shows. So the upstream Apache arm carries no NOTICE obligation, and
  none passes to the port.
* **MIT**: no. The only condition is notice retention, `AK/LICENSE-MIT:11-13`.
* **BSD-3-Clause**: no. The three conditions at `AK/LICENSE.chromium:7-15`
  require notice reproduction "in the documentation and/or other materials
  provided with the distribution". A `NOTICE.md` is one way to satisfy that. A
  README is another.
* **LGPL-2.1**: not applicable. The port copies no Meson file.

**Decision.** The port ships a `NOTICE.md` anyway, for three reasons. The house
requires one: `foundation-libs/AGENTS.md:38` records that all fifteen forks
carry `NOTICE.md`. The BSD-3-Clause binary condition is easier to demonstrate
with one file than with a README section. And `NOTICE.md` is the natural home
for the per-file inventory that section 6.2 needs anyway.

### 6.2 File checklist

#### Licence files, copied verbatim

- [ ] `LICENSE-APACHE` in the port root. Byte-for-byte copy of
      `AK/LICENSE-APACHE` (176 lines). Do not add the Apache appendix, and do
      not remove the omission that upstream has. Apache 4(a):
      "You must give any other recipients of the Work or Derivative Works a
      copy of this License."
- [ ] `LICENSE-MIT` in the port root. Byte-for-byte copy of
      `AK/LICENSE-MIT` (23 lines). Note that it carries no copyright line, so
      it is the permission notice only. The copyright notice lives in the
      per-file headers, and MIT requires both. See item F1.
- [ ] `LICENSE.chromium` in the port root. Byte-for-byte copy of
      `AK/LICENSE.chromium` (27 lines). Satisfies BSD-3-Clause conditions 1 and
      2 at `:7-12`.
- [ ] **Do not copy** `AKC/COPYING.LIB`, `AKC/meson.build`,
      `AKC/meson_options.txt` or `AKC/meson/**`. That is the LGPL-2.1 carve-out
      in `AKC/README.md:116`, and the port has no Meson build.

#### Per-file headers, one per translated Zig file

- [ ] **F1.** Every `.zig` file translated from an AccessKit source file starts
      with the AccessKit notice, matching `AK/accesskit/src/geometry.rs:1-4`:

  ```
  // Copyright 2021 The AccessKit Authors. All rights reserved.
  // Licensed under the Apache License, Version 2.0 (found in
  // the LICENSE-APACHE file) or the MIT license (found in
  // the LICENSE-MIT file), at your option.
  //
  // Translated from <upstream path> at commit <hash> to Zig.
  //
  // SPDX-License-Identifier: MIT OR Apache-2.0
  ```

  The year is the year in the upstream header for that file, not the port's
  year. The SPDX line is optional. `[INFERENCE]` If it is added, the house
  precedent in `spglib/tools/check_provenance.sh:47-51` is a gate that greps
  for it, and the gate must run.

- [ ] **F2.** If the upstream file also carried a derivation header, the port
  file carries it too, unchanged. Concretely:

  * From one of the twelve files in 3.2, add verbatim
    `// Derived from Chromium's accessibility abstraction.` or
    `// Derived from the Flutter engine.`, then the original holder line with
    its year, then
    `// Use of this source code is governed by a BSD-style license that can be`
    and `// found in the LICENSE.chromium file.`
  * From `AK/accesskit/src/geometry.rs`, add the kurbo block, lines 6 to 10.
  * From `AK/adapters/android/src/inject.rs`, add the jni-rs block, lines 6 to
    10.
  * From `AK/adapters/unix/src/executor.rs`, add the zbus block, lines 6 to 8.

- [ ] **F3.** Every `.zig` file translated from a `AKC/src/*.rs` file carries the
      rustls-ffi block **with the broken pointer removed**. Write
      `the LICENSE-MIT file` or `the LICENSE-APACHE file` and add
      `// The ISC text is not shipped upstream; see NOTICE.md.`. Do not write
      `the LICENSE-ISC file`. See 3.5 and action item A9.

- [ ] **F4.** The port's own files, those with no AccessKit upstream, carry the
      port's own notice only. **(legal)** The text of that notice depends on
      the decision in action item A1.

#### The port's own licence

- [ ] **O1.** `LICENSE` in the port root. **(legal)** The grant is undecided.
      Section 8, action item A1, states the options and the house precedent.
      `[INFERENCE]` The house precedent in
      `foundation-libs/utf8proc/FORK-LICENSE.md:9-14` is to name a grant, name
      the SPDX identifier, name the date, and name the person who chose it.

#### The NOTICE file

- [ ] **N1.** `NOTICE.md` in the port root. Shape follows
      `foundation-libs/spglib/NOTICE.md:1-73`: an "Upstream" section that
      quotes each grant verbatim, then "This fork" section that lists what the
      port changed.
- [ ] **N2.** `NOTICE.md` names the upstream AccessKit commit and the
      accesskit-c commit, so a reader can find the exact source of every
      translated file.
- [ ] **N3.** `NOTICE.md` carries the per-file Chromium inventory, all twelve
      rows from the table in 3.2, with the holder and the year for each.
- [ ] **N4.** `NOTICE.md` records the zio upstream pin, `ZAK/build.zig.zon:30`, and
      states that the zio licence text is reproduced because zio's
      `build.zig.zon:6-11` does not ship it.
- [ ] **N5.** `NOTICE.md` records the Flutter rows separately from the Chromium
      rows, because the holder is different.
- [ ] **N6.** `NOTICE.md` records the kurbo, jni-rs, zbus and rustls-ffi
      attributions from the table in 3.5.

#### The README

- [ ] **R1.** A "License" section that names the port's own grant. **(legal)**
      Depends on action item A1.
- [ ] **R2.** A sentence stating the upstream choice, in the same shape as
      `AK/README.md:76`:
```
AccessKit is licensed under the Apache License, Version 2.0 or the MIT
license, at your option.
```
- [ ] **R3.** A sentence stating that significant portions are derived from
      Chromium and covered by its BSD-style licence, in the same shape as
      `AK/README.md:82`. This sentence is required in practice, because
      BSD-3-Clause condition 2 asks for the notice in binary distributions'
      documentation.
- [ ] **R4.** A "Provenance" section naming: the AccessKit core repository and
      commit, the accesskit-c repository and commit, goose with its version and
      licence, zio with its version, licence and pin, and the statement that
      the port is an independent work that is not endorsed by AccessKit or
      Google.
- [ ] **R5.** **No endorsement claim.** Nothing in the README, the package
      description, the release notes or the code comments may use the name
      "Google Inc." or the names of its contributors to endorse or promote the
      port. `AK/LICENSE.chromium:13-15`. **(legal)** The borderline between
      stating origin and implying endorsement is a reviewer's call.
- [ ] **R6.** A statement that the port is a translation and not a wrapper, and
      that it does not embed Rust code. This is not a licence obligation. It
      answers the question a reader will ask after seeing upstream attribution.

#### Packaging

- [ ] **P1.** Add `LICENSE`, `LICENSE-APACHE`, `LICENSE-MIT`, `LICENSE.chromium`
      and `NOTICE.md` to `.paths` in `ZAK/build.zig.zon`. The current list at
      `ZAK/build.zig.zon:46-54` is `build.zig`, `build.zig.zon`, `src`, `docs`,
      `README.md`, `AGENTS.md`, `zlint.json`. It ships no licence file at all.
      Apache 4(a) requires giving recipients a copy of the licence, and MIT
      requires including the notice in copies. A `.paths` list that omits the
      licence files fails both.
- [ ] **P2.** Ship `NOTICE.md` in the binary distribution as well as the source.
      BSD-3-Clause condition 2 asks for it "in the documentation and/or other
      materials provided with the distribution".
- [ ] **P3.** The install step installs `NOTICE.md` and the three licence files
      next to the library and the header.

#### The gate

- [ ] **G1.** Add `tools/check_licence.sh` or an equivalent Zig step. It must
      fail the build when any check below fails. Model it on
      `foundation-libs/spglib/tools/check_provenance.sh:29-54`.
- [ ] **G2.** Gate check: each of `LICENSE-APACHE`, `LICENSE-MIT` and
      `LICENSE.chromium` is present and byte-identical to the upstream copy at
      the pinned commit.
- [ ] **G3.** Gate check: `NOTICE.md` exists and names each licence file.
- [ ] **G4.** Gate check: every `.zig` file under `src/` carries the AccessKit
      notice, with a named exception list for the port's own files.
- [ ] **G5.** Gate check: every `.zig` file derived from one of the twelve files
      in 3.2 carries the Chromium or Flutter notice.
- [ ] **G6.** Gate check: the string `LICENSE-ISC` appears nowhere in the tree.
- [ ] **G7.** Gate check: `.paths` in `build.zig.zon` names every licence file
      the port ships.
- [ ] **G8.** Gate check: no file contains `the LICENSE-ISC file`, and no file
      claims endorsement by Google or by the AccessKit authors.

### 6.3 Exact required notice text

For each licence, the text that must appear.

**Apache-2.0.** The licence text itself is the notice. Copy
`AK/LICENSE-APACHE` verbatim. The notice that goes in a modified file is
`AK/LICENSE-APACHE:97-98`:

> (b) You must cause any modified files to carry prominent notices stating that
> You changed the files; and

**MIT.** `AK/LICENSE-MIT:11-13`, the whole of the condition:

> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.

The permission notice is `AK/LICENSE-MIT:1-9` plus `:15-23`. The copyright
notice is the per-file line, for example
`// Copyright 2021 The AccessKit Authors. All rights reserved.`

**BSD-3-Clause.** `AK/LICENSE.chromium:1` plus `:7-27`. The whole file is the
notice, and condition 2 fixes where it goes in a binary distribution:

> Redistributions in binary form must reproduce the above copyright notice,
> this list of conditions and the following disclaimer in the documentation
> and/or other materials provided with the distribution.

**LGPL-2.1.** Not applicable. No Meson file is copied.

**The port's own grant.** **(legal)** Undecided. See action item A1.

## 7. House precedent

### 7.1 How `foundation-libs` records a licence

`FORKS.json` is the machine-readable ledger. Each fork entry carries a
`licence` object. The flat shape, at `FORKS.json:1531-1538` for spglib:

```json
"licence": {
  "spdx": "BSD-3-Clause",
  "files": [
    "spglib/COPYING"
  ],
  "obligations": "retain copyright notice and licence text",
  "status": "SOURCE-CONFIRMED"
}
```

The same shape appears at `FORKS.json:1686-1690` for tzdata,
`:2158-2165` for htscodecs, `:2316-2322` for random123 and `:6781-6788` for
inchi. Four fields always: `spdx`, `files`, `obligations`, `status`. The
`status` value comes from the vocabulary at `FORKS.json:7-17`.

The richer shape nests when a package has more than one grant. blake3 at
`FORKS.json:2611-2622`:

```json
"licence": {
  "upstream": {
    "spdx": "CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception",
    "files": ["LICENSE_A2", "LICENSE_A2LLVM", ...],
    "obligations": "retain each licence text verbatim; the Apache arms require the notice, a statement of changed files and the patent-grant termination clause",
    "status": "SOURCE-CONFIRMED"
  },
  "own_code": { ... }
}
```

sheenbidi at `FORKS.json:4036-4049` and s2geometry at `:8780-8796` use the same
two-key nesting, with extra sibling keys such as
`carried_material_with_its_own_terms`, `vendored_dependency` and
`recorded_not_as_bundled_licences`.

**The port needs the rich shape**, because the AccessKit material is exactly
the blake3 case: several grants, one of them file-scoped. `NOTICE.md` is the
`files` inventory and `FORK-LICENSE.md` is the `own_code` grant.

`FORKS.json:375-378` records a licence-based exclusion, which shows the
`EXCLUDED` disposition:

```json
{
  "version": "2.0.2",
  "licence": "AGPL-3.0-or-later in the library itself",
  "reason": "the copyleft is in the library, not in optional tooling, so the existing selection policy that excludes GPL-family source forks applies to the library itself. This is not a licence-unverified decision and not a user block.",
  "status": "excluded on licence"
}
```

Nothing equivalent applies to the port. Every licence in section 4 is
permissive.

### 7.2 What `licence_consistency.py` checks

The script is 199 lines. Its own docstring at
`licence_consistency.py:8-15` states the purpose:

> This tool attacks the error class instead: it extracts every (library,
> licence) pair asserted anywhere in the corpus and reports any library for
> which two documents assert *different* licences.
>
> It deliberately does NOT decide which claim is right - that requires reading
> upstream. It produces the worklist.

Mechanically:

1. It scans `foundation/docs/*.md`, `foundation/docs/_meta/*.md` and
   `foundation/INDEX.md`, at `licence_consistency.py:99`.
2. It keeps markdown table rows with at least three cells,
   `licence_consistency.py:53-61`.
3. It takes the first cell as the library name, normalises it,
   `licence_consistency.py:82-87`, and falls back to the second cell when the
   first is an ordinal, `:111-118`.
4. It finds a licence expression in the remaining cells with the regex at
   `:127-137`. The expression may be a two-arm join such as
   `Apache-2.0 OR MIT`.
5. It canonicalises separators, `:156-164`. The comment at `:157-161` records
   why: a naive `or` substitution splits `LGPL-2.1-or-later` and manufactures
   conflicts.
6. It reports every library with more than one distinct canonical expression,
   `:166-195`, and exits 1.

**What the port takes from it.** The expression spelling. Write
`MIT OR Apache-2.0`, not `MIT/Apache-2.0` and not `Apache-2.0 or MIT`. The
canonicaliser accepts a lowercase `or` and a slash, but using one form
everywhere avoids the false conflicts the script is designed to catch.

**What the port does not take from it.** The script points at `foundation/docs`,
not at `ZAK/docs`. `[INFERENCE]` Running it over `ZAK/docs` is a small change
and would catch a licence stated two ways across the port's own documents. That
is action item D2, and it is a convenience, not an obligation.

### 7.3 The shape of a licence record in this house

Four artefacts, one per concern.

| Artefact | Purpose | Example |
|---|---|---|
| `LICENSE` or `FORK-LICENSE.md` | The grant, the SPDX identifier, the date, the chooser | `foundation-libs/utf8proc/FORK-LICENSE.md:1-47` |
| `NOTICE.md` | The per-file inventory of every grant in the tree | `foundation-libs/utf8proc/NOTICE.md:1-288`, `foundation-libs/spglib/NOTICE.md:1-147` |
| `UPSTREAM.md` | Provenance: pin, digest, and where each part came from | listed for all fifteen at `FORKS.json:38` |
| A gate script | The check that fails when an obligation breaks | `foundation-libs/spglib/tools/check_provenance.sh` |

`FORK-LICENSE.md` states the four things a licence record needs,
`utf8proc/FORK-LICENSE.md:9-14`:

> **MIT**, SPDX identifier `MIT`. Chosen by the owner of this working copy on
> **2026-10-04** as this project's licence for fork-authored additions, matching its
> primary upstream term - the MIT "expat" grant at `LICENSE.md:1-28`, restated in
> prose at `README.upstream.md:23-28`. This is a direct owner authorization for this
> repository, not an inference from the upstream terms and not a grant by any
> upstream author.

It also handles the collective holder, `:40-43`:

> `the utf8proc Zig SDK fork authors` is a collective holder: no individual
> identity was supplied and none is invented, and no upstream author is credited
> with fork work. A redistribution that needs a named holder gets one from the
> owner.

`NOTICE.md` opens by stating why one label is not enough,
`utf8proc/NOTICE.md:3-13`:

> This file is the per-file licence record for this package. It exists because a
> single label for this tree would be **wrong** [...]
>
> **Nothing in this package claims one licence for the whole tree.** "MIT" is the
> term for the library and for most of its material; it is not the term for
> everything here, and no summary line anywhere in this repository says it is.

`spglib/NOTICE.md:1-49` shows the simpler shape that fits the port: "Upstream",
the verbatim grant, then per-file exceptions with their reasons, then
"This fork" with a bullet list of changes.

The gate answers six questions, `check_provenance.sh:7-12`:

> #   1. Is the BSD 3-Clause licence text still present and unmodified?
> #   2. Does every upstream C file still carry its SPDX identifier?
> #   3. Do upstream sources match the pin plus the two recorded patches?
> #   4. Do the provenance records agree with the build script and the manifest?
> #   5. Is the preserved upstream README still upstream's, byte for byte?

and exits non-zero on the first failure, `:4-5`:

> # Run from the repository root. Exits non-zero on the first failed check, so CI
> # shows which obligation broke rather than a list of them.

### 7.4 The rules the house states about licences

`foundation-libs/AGENTS.md:207-238` is section 8, "Licence, provenance,
privacy". The four sentences that bind the port:

> A private repository removes no upstream obligation.
> (`foundation-libs/AGENTS.md:209`)

> Per-file exceptions go in `NOTICE.md`, and provenance per fork in
> `UPSTREAM.md`. (`foundation-libs/AGENTS.md:215`)

> Name the term and the line, keep the guard out of the range, and let
> `NOTICE.md` carry the inventory; never reduce a tree to the licence of its
> most prominent file. (`foundation-libs/AGENTS.md:227-228`)

> Material a package carries is licensed by its own file, not automatically by
> the compiled core's licence. (`foundation-libs/AGENTS.md:230`)

`foundation-libs/AGENTS.md:234` adds:

> Do not attribute fork additions to upstream authors.

`foundation-libs/WISDOM.md` entry W40 states the vendoring rule,
`foundation-libs/WISDOM.md:868-875`:

> When a dependency's source is copied into the tree, copy its licence verbatim
> beside the copy and count that file in the package's integrity records.

The port copies no dependency source. It fetches goose and zio as packages. The
rule does not apply. If that changes, the rule applies immediately.

`foundation-libs/WISDOM.md:37-38` records the open question this document must
not answer for the owner:

> The per-file licence audit of carried material is closed where it was run, and
> the licence of each fork's own files is the owner's unassigned decision, not
> a build result.

`foundation/CONTRACT.md:121-122` sets the evidence rule for a licence claim:

> Do not invent versions, dates, licenses, or star counts. If you could not
> confirm a version, write `unverified` rather than guessing.

`CONTRACT.md:66` gives the table shape this document follows for section 4, with
`CONTRACT.md:70` requiring the exact SPDX identifier where one is known.

## 8. Action items

### 8.1 Required before the first public release

| # | Item | Owner | Why |
|---|---|---|---|
| A1 | **LEGAL DECISION.** Choose the licence the port asserts over its own files. Record it in `FORK-LICENSE.md` naming the grant, the SPDX identifier, the date and the chooser. | Legal, then owner | Nothing in the tree asserts a licence for port-authored code today. See 8.3. |
| A2 | **LEGAL DECISION.** Confirm the reading in 2.6: the port material is `(MIT OR Apache-2.0) AND BSD-3-Clause`, not `MIT OR Apache-2.0 OR BSD-3-Clause`. | Legal | The difference decides whether the Chromium notices are optional. They are not, under the reading in this document. |
| A3 | **LEGAL DECISION.** Confirm the derivative-work reading for translation in every target jurisdiction. | Legal | Section 5.6 question 1. |
| A4 | **LEGAL DECISION.** Confirm that the project name `zaccesskit` and the package description do not imply endorsement by Google or by the AccessKit authors. | Legal | `AK/LICENSE.chromium:13-15`. |
| A5 | **LEGAL DECISION.** Review the Apple and Windows SDK terms for the platform adapters, on a host that has those SDKs. | Legal, on a Mac and on Windows | This host has neither SDK, so this document records no terms. Section 4.4. |
| A6 | Copy `ZIO/LICENSE` verbatim into the port and cite it. | Engineer | `ZIO/build.zig.zon:6-11` does not ship the licence, so the port is the last carrier. Section 4.2. |
| A7 | Copy `GOOSE/LICENSE` verbatim into the port and cite it. | Engineer | `GOOSE/build.zig.zon:10-16` ships it, but a binary recipient never sees the package. Section 4.1. |
| A8 | Copy `LICENSE-APACHE`, `LICENSE-MIT` and `LICENSE.chromium` into the port root, byte for byte. | Engineer | Apache 4(a), MIT, BSD-3-Clause conditions 1 and 2. |
| A9 | Do not reproduce the `LICENSE-ISC` pointer from `AKC/src/lib.rs:10`. Write an accurate pointer or none. | Engineer | The file does not exist upstream. Section 3.5. |
| A10 | Add the Chromium and Flutter notices to any port C header that reproduces text derived from `AKC/include/accesskit.h`. | Engineer | The generated header dropped them. Section 3.6. |
| A11 | Add the change notice to every translated file, per Apache 4(b). | Engineer | `AK/LICENSE-APACHE:97-98`. Checklist item F1. |
| A12 | Write `NOTICE.md` with the per-file inventory. | Engineer | Checklist items N1 to N6. |
| A13 | Add every licence file and `NOTICE.md` to `.paths` in `build.zig.zon`, and install them. | Engineer | Checklist items P1 to P3. Without this the packaged port ships no licence at all. |
| A14 | Write `tools/check_licence.sh`, wired into the build, and make it fail on a missing or altered notice. | Engineer | Checklist items G1 to G8. House precedent: `spglib/tools/check_provenance.sh`. |
| A15 | Write the README License and Provenance sections. | Engineer | Checklist items R1 to R6. |
| A16 | Confirm no Meson file was copied, and add a gate check that greps for `meson.build` and `COPYING.LIB`. | Engineer | LGPL-2.1 carve-out, `AKC/README.md:116`. |
| A17 | Record the port's provenance: both upstream repositories, both commits, and the twelve Chromium-derived files. | Engineer | Checklist item N2, and house rule at `foundation-libs/AGENTS.md:215`. |

### 8.2 May be deferred

| # | Item | Why it can wait |
|---|---|---|
| D1 | Per-file `SPDX-License-Identifier` lines. | The house gate at `spglib/tools/check_provenance.sh:47-51` uses them, but the obligation is satisfied by the notice block. Add them if the gate is written to require them. |
| D2 | Run `licence_consistency.py` over `ZAK/docs`. | The script points at `foundation/docs`. Porting it is a convenience that catches a licence stated two ways. |
| D3 | A machine-readable licence ledger in the house `FORKS.json` style. | The house writes such a ledger for its own forks. The port is not a foundation-libs fork. A table in `NOTICE.md` is enough until the port grows its own forks. |
| D4 | `UPSTREAM.md` as a separate document. | The house requires it for forks. For the port, a Provenance section in the README plus the pin in `NOTICE.md` covers it. |
| D5 | An integrity digest manifest. | House rule at `foundation-libs/WISDOM.md:868-875` applies to copied dependency source. The port copies none. |
| D6 | Verifying the twelve headers against a Chromium checkout. | The headers are the upstream record. Section 3.4 grades that as `SOURCE-CONFIRMED` and marks the check as optional. |

### 8.3 Legal decisions, stated as decisions

Four questions are legal, not engineering. They are listed once more, in the
form in which they should be answered.

**L1. What licence does the port assert over its own code?**
Three inputs. First, the port is a derivative of Apache-2.0-or-MIT material, so
it may distribute its own additions under any terms, per
`AK/LICENSE-APACHE:123-128`. Second, the BSD-3-Clause arm does not restrict the
own-code terms at all. Third, the house precedent is to match the primary
upstream term, as `foundation-libs/utf8proc/FORK-LICENSE.md:9-14` records.
Options: `MIT OR Apache-2.0`, matching upstream; `MIT` alone; `Apache-2.0`
alone. `[INFERENCE]` The first matches both upstream choices at once and is the
least surprising for a consumer. That is a recommendation, not a decision.

**L2. Is the port's material `(MIT OR Apache-2.0) AND BSD-3-Clause`?**
Section 2.6 argues yes, because `AK/README.md:82` puts the Chromium material in
a sentence of its own, outside the "at your option" paragraph at `:76`, and
because no SPDX expression naming all three exists anywhere in either tree. If
a reviewer disagrees, the port ships more notices than it needs, which is not a
failure.

**L3. Does the project name imply endorsement?**
`AK/LICENSE.chromium:13-15` forbids using Google's name or its contributors'
names "to endorse or promote products derived from this software". Naming the
upstream in order to state origin is not the same act, in this document's
reading. A reviewer draws the line, and the README should carry a disclaimer
under checklist item R4 either way.

**L4. What are the SDK terms on Apple and Windows platforms?**
This document records none, because neither SDK is on this host. The port
binds NSAccessibility, UIAccessibility and UI Automation. `[INFERENCE]` These
are platform surfaces under the vendor's SDK agreement rather than
redistributable libraries, so the port ships no Apple or Microsoft code. A
reviewer confirms this before release, and the check must run on a machine that
has the SDK.

## 9. House rules, rule by rule

`~/ozai/AGENTS.md` section 2 is
"Architecture: extreme-testable by default". This document has no
architecture, so most rules do not touch it. Three do.

| House rule | Effect on this document |
|---|---|
| `io: std.Io` threaded explicitly, never global | No effect |
| Network logic is pure over decoded bytes | No effect |
| State is a parameter, not a capture | No effect |
| Wire compatibility is a test, not a comment, `ozai/AGENTS.md:89-91` | **Direct conflict, and the port loses.** See 9.1. |
| Errors are values, explicit error sets | No effect |
| Comptime exhaustiveness | No effect |
| `unreachable` is a claim | No effect |
| Determinism, seeds injected, `Smith` fuzz at every decoder boundary | No effect on licensing. The fixtures it produces become licence-neutral test data. |
| No backwards compatibility, no shims, clean cutover | **Looks like a conflict, and is not.** See 9.2. |
| Zero deps unless justified | Reinforces the section 4 result: two dependencies, both MIT. |

### 9.1 Wire compatibility is a test, not a comment

`ozai/AGENTS.md:89-91` reads:

> Wire compatibility is a test, not a comment. Any claim of iroh
> interoperability is a golden-vector test carrying bytes captured from the Rust
> implementation, or it is an unverified claim.

The port philosophy says no `cargo` at any time, and no Rust in the build. Those
two rules together create a licence-adjacent constraint that the house rule
catches. If the port captures golden vectors from `accesskit-c` by running the
Rust library, it has used Rust as a fixture generator. That is not a licence
problem, but it is a reproducibility problem, and it leaves the vectors with no
recorded provenance.

The resolution is already written into the port philosophy: **recorded
fixtures**. Every golden vector in the port's test suite carries the commit it
came from and the command that produced it, recorded once by hand, then never
regenerated. Section 6 item N2 exists to hold that provenance. `[INFERENCE]` The
licence angle is small: a fixture recorded from upstream output is data derived
from a BSD-3-Clause and Apache-2.0-or-MIT work, so `NOTICE.md` should name it.

### 9.2 Clean cutover against retain-the-notices

The house forbids backwards compatibility, shims and aliases. A licence notice
is not any of those. A notice is metadata about origin. It has no effect on the
API surface, no effect on behaviour, and no effect on the module graph. The port
keeps every notice upstream keeps, and keeps none of upstream's API.

The house rule that does bite is `foundation-libs/AGENTS.md:234`:

> Do not attribute fork additions to upstream authors.

So a translated file carries **both** notices and neither claims the other. The
AccessKit notice names the AccessKit authors. The port's own notice names the
port's authors. The Chromium notice names The Chromium Authors. None of the
three claims credit for the other two. Checklist items F1 and F4 implement this.

### 9.3 What this document does not settle

Three things are deliberately left open, and each is handed to a named owner in
section 8.

1. The port's own licence. Action item A1, legal decision L1.
2. The endorsement boundary in writing. Action item A4, legal decision L3.
3. Apple and Windows SDK terms. Action item A5, legal decision L4.

Everything else in this document is either read off a file or marked
`[INFERENCE]`.
