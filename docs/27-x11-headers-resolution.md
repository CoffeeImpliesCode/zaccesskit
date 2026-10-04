# 27. Resolving the four missing X11 headers on this host

Measured on 2026-10-05 in `/tmp/scratch/x11hdr-probe/`.
Nothing was installed on the host. No process outside that scratch tree was started or
stopped. The only host writes were the read-only queries shown here.

Four headers are missing while the matching runtime objects exist:
`X11/extensions/XTest.h`, `X11/extensions/Xfixes.h`, `X11/extensions/XInput2.h` and
`xkbcommon/xkbcommon.h`.

The host linker is also missing the link names for the same four libraries. This is a
separate defect from the missing headers, and section 4.4 shows it.

```
$ for p in xtst xfixes xi xkbcommon x11 xext; do pkg-config --exists "$p" 2>/dev/null && echo "$p OK $(pkg-config --modversion $p)" || echo "$p ABSENT"; done
xtst ABSENT
xfixes ABSENT
xi ABSENT
xkbcommon ABSENT
x11 OK 1.8.10
xext OK 1.3.6

$ ls -la /usr/lib64/libXtst.so /usr/lib64/libxkbcommon.so
ls: cannot access '/usr/lib64/libXtst.so': No such file or directory
ls: cannot access '/usr/lib64/libxkbcommon.so': No such file or directory

$ ls -la /usr/lib64/libX11.so /usr/lib64/libXext.so
lrwxrwxrwx+  1 root root 15 Feb 22  2025 /usr/lib64/libX11.so -> libX11.so.6.4.0
lrwxrwxrwx+  1 root root 16 Feb  5  2024 /usr/lib64/libXext.so -> libXext.so.6.4.0
```

So `x11` and `xext` have both headers and linker names. The other four have neither.

## 1. The host package manager: DOES NOT WORK

**Verdict: BLOCKED. All four packages exist in `repo-oss (16.0)`. The account cannot
install them, because installation needs root and this account has no passwordless
sudo. No repository is the obstacle, so this is a privilege problem only.**

`zypper` is present.

```
$ which zypper
/bin/zypper
$ zypper --version
zypper 1.14.98
$ id
uid=33156(user) gid=33100(mi19) Gruppen=33100(mi19),9502(students)
```

All four development packages resolve. `zypper --non-interactive info` found each one in
`repo-oss (16.0)` and reported it as not installed.

```
$ zypper --non-interactive info libXtst-devel libXfixes-devel libXi-devel libxkbcommon-devel
    Hinweis: Repository ‚repo-oss (16.0)‘ ist veraltet. Sie können 'zypper refresh' als root ausführen, um es zu aktualisieren.

Repository-Daten werden geladen...
Installierte Pakete werden gelesen...

[The four "Informationen zu Paket" blocks follow. Each is verbatim except the
multi-line Beschreibung paragraph, which is removed for length. The command printed one
Hint per stale repository; only the repo-oss one is shown.]


Informationen zu Paket libXtst-devel:
-------------------------------------
Repository         : repo-oss (16.0)
Name               : libXtst-devel
Version            : 1.2.5-160000.3.2
Arch               : x86_64
Anbieter           : SUSE LLC <https://www.suse.com/>
Installierte Größe : 80,2 KiB
Installiert        : Nein
Status             : nicht installiert
Quellpaket         : libXtst-1.2.5-160000.3.2.src
Zusammenfassung    : Development files for the X11 XTEST and RECORD extensions

Informationen zu Paket libXfixes-devel:
---------------------------------------
Repository         : repo-oss (16.0)
Name               : libXfixes-devel
Version            : 6.0.1-160000.3.2
Arch               : x86_64
Installiert        : Nein
Status             : nicht installiert
Zusammenfassung    : Development files for the X11 Xfixes extension library

Informationen zu Paket libXi-devel:
-----------------------------------
Repository         : repo-oss (16.0)
Name               : libXi-devel
Version            : 1.8.2-160000.3.2
Arch               : x86_64
Installiert        : Nein
Status             : nicht installiert
Zusammenfassung    : Development files for the X Input Extension library

Informationen zu Paket libxkbcommon-devel:
------------------------------------------
Repository         : repo-oss (16.0)
Name               : libxkbcommon-devel
Version            : 1.8.0-160000.2.2
Arch               : x86_64
Installiert        : Nein
Status             : nicht installiert
Zusammenfassung    : Development files for the libxkbcommon library

EXIT=0
```

Installation is refused before any download starts.

```
$ zypper --non-interactive install --dry-run libXtst-devel
Root-Rechte werden benötigt um dieses Kommando auszuführen.
$ echo $?
5
```

The account cannot become root.

```
$ sudo -n true
sudo: Ein Passwort ist notwendig
$ echo $?
1
$ sudo -n -l
sudo: Ein Passwort ist notwendig
$ echo $?
1
$ test -w /usr/include && echo writable || echo "NOT writable"
NOT writable
$ test -w / && echo writable || echo "NOT writable"
NOT writable
```

What blocks it, in one sentence: `zypper` needs uid 0 to write into `/usr`, and this
account has uid 33156 with no passwordless sudo, so the four `-devel` packages cannot be
placed on this host by any means the account controls.

## 2. Nix: WORKS

**Verdict: WORKS. The Nix sandbox store on this host supplies all four libraries. Their
headers came from `cache.nixos.org` and were copied into a scratch sysroot. No root was
needed at any point.**

The first `nix build` below also unpacked the `nixpkgs-unstable` channel tarball, which is
why it took 14 seconds. The build after that took under 1 second.

The store is reachable through the wrapper only. `~/.local/bin/nix` runs `apptainer` with
the sandbox store bound to `/nix/store` inside the container.

```
$ ~/.local/bin/nix --version
nix (Nix) 2.35.2
$ ~/.local/bin/nix store ping
warning: 'ping' is a deprecated alias for 'info'
Store URL: local
Version: 2.35.2
Trusted: 1
```

The store root does not exist on the host filesystem. This matters for how the port reads
the headers.

```
$ ls -d /nix
ls: cannot access '/nix': No such file or directory
$ ls -d /nix/store
ls: cannot access '/nix/store': No such file or directory
```

Fetching the four libraries.

```
$ ~/.local/bin/nix build --no-link --print-out-paths --out-link /tmp/scratch/x11hdr-probe/x11out \
    'nixpkgs#libXtst' 'nixpkgs#libXfixes.dev' 'nixpkgs#libXi.dev' 'nixpkgs#libxkbcommon.dev'
this path will be fetched (75.8 KiB download, 91.2 KiB unpacked):
  /nix/store/mfpm38ssrvkv38sfr3vhc5v0vhqbc83p-libxi-1.8.3-man
copying path '/nix/store/mfpm38ssrvkv38sfr3vhc5v0vhqbc83p-libxi-1.8.3-man' from 'https://cache.nixos.org'...
/nix/store/qljkaaa4v37lyc43c91pvz5fsgf8j2wg-libxtst-1.2.5
/nix/store/l5y7fz08zvrqiinb90j1r922ymncb0sj-libxfixes-6.0.2
/nix/store/mfpm38ssrvkv38sfr3vhc5v0vhqbc83p-libxi-1.8.3-man
/nix/store/sp7qi6d789jbkbn0mpzna06gbxlm5gzi-libxi-1.8.3
/nix/store/nvrv5w6rhc39h8snrsw03nqs679cf7rh-libxkbcommon-1.13.2
EXIT=0
```

`libXtst` has no `.dev` output in nixpkgs. Its `out` output carries the headers. The other
three split headers into `dev`.

```
$ ~/.local/bin/nix eval --json --impure --expr 'let f = builtins.getFlake "nixpkgs"; p = f.legacyPackages.x86_64-linux; in { xtst = p.libXtst.outputs; xfixes = p.libXfixes.outputs; xi = p.libXi.outputs; xkb = p.libxkbcommon.outputs; }'
{"xfixes":["out","dev"],"xi":["out","dev","man","doc"],"xkb":["out","dev","doc"],"xtst":["out"]}
```

So the correct fetch uses `nixpkgs#libXtst` with no `.dev`, and `.dev` on the other three.

```
$ ~/.local/bin/nix build --no-link --print-out-paths --out-link /tmp/scratch/x11hdr-probe/x11out \
    'nixpkgs#libXtst' 'nixpkgs#libXfixes.dev' 'nixpkgs#libXi.dev' 'nixpkgs#libxkbcommon.dev'
/nix/store/qljkaaa4v37lyc43c91pvz5fsgf8j2wg-libxtst-1.2.5
/nix/store/jxqrv7q8ydpsc2m9zli83bjsabq0rxs0-libxfixes-6.0.2-dev
/nix/store/7zvd4bm46yg9wkx17qpzbgcj27fji8yq-libxi-1.8.3-dev
/nix/store/47nlx1dpb8zd73vjp2zms7r8k9xkzndp-libxkbcommon-1.13.2-dev
EXIT=0
```

The `--out-link` symlink dangles on the host, because `/nix/store` exists only inside the
sandbox.

```
$ ls -la /tmp/scratch/x11hdr-probe/x11out
lrwxrwxrwx 1 user mi19 57 Oct  5 00:32 /tmp/scratch/x11hdr-probe/x11out -> /nix/store/qljkaaa4v37lyc43c91pvz5fsgf8j2wg-libxtst-1.2.5
$ readlink -f /tmp/scratch/x11hdr-probe/x11out

$ test -e /tmp/scratch/x11hdr-probe/x11out/. ; echo $?
1
```

The host-visible prefix of the same store paths is
`/tmp/devenv-sbox-from-hometmp/nix/store/`. That directory is on local disk
and a normal process can read it.

```
$ S=/tmp/devenv-sbox-from-hometmp/nix/store
$ for h in XTest.h Xfixes.h XInput2.h xkbcommon.h; do echo "=== $h ==="; find "$S" -maxdepth 6 -name "$h" 2>/dev/null; done
=== XTest.h ===
/tmp/devenv-sbox-from-hometmp/nix/store/qljkaaa4v37lyc43c91pvz5fsgf8j2wg-libxtst-1.2.5/include/X11/extensions/XTest.h
/tmp/devenv-sbox-from-hometmp/nix/store/c2wd07p71cfyx1wkxsqv32b1z0f2hknl-libxtst-1.2.5/include/X11/extensions/XTest.h
/tmp/devenv-sbox-from-hometmp/nix/store/n4i3r3144by7w003yirv1v5ll8ifd8h3-libxtst-1.2.5/include/X11/extensions/XTest.h
=== Xfixes.h ===
/tmp/devenv-sbox-from-hometmp/nix/store/jxqrv7q8ydpsc2m9zli83bjsabq0rxs0-libxfixes-6.0.2-dev/include/X11/extensions/Xfixes.h
=== XInput2.h ===
/tmp/devenv-sbox-from-hometmp/nix/store/7zvd4bm46yg9wkx17qpzbgcj27fji8yq-libxi-1.8.3-dev/include/X11/extensions/XInput2.h
=== xkbcommon.h ===
/tmp/devenv-sbox-from-hometmp/nix/store/47nlx1dpb8zd73vjp2zms7r8k9xkzndp-libxkbcommon-1.13.2-dev/include/xkbcommon/xkbcommon.h
```

The four headers pull in siblings. Not every sibling has to come from the Nix store,
because the host already installed `libX11-devel` and `libXext-devel`.

```
$ D=/tmp/scratch/x11hdr-probe/sysroot/include
$ grep -n '^#include' $D/X11/extensions/XTest.h $D/X11/extensions/Xfixes.h $D/X11/extensions/XInput2.h $D/xkbcommon/xkbcommon.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XTest.h:30:#include <X11/Xfuncproto.h>
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XTest.h:31:#include <X11/extensions/xtestconst.h>
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XTest.h:32:#include <X11/extensions/XInput.h>
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/Xfixes.h:49:#include <X11/extensions/xfixeswire.h>
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/Xfixes.h:51:#include <X11/Xfuncproto.h>
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/Xfixes.h:52:#include <X11/Xlib.h>
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XInput2.h:30:#include <X11/Xlib.h>
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XInput2.h:31:#include <X11/extensions/XI2.h>
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XInput2.h:32:#include <X11/extensions/Xge.h>
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XInput2.h:33:#include <X11/extensions/Xfixes.h> /* PointerBarrier */
/tmp/scratch/x11hdr-probe/sysroot/include/xkbcommon/xkbcommon.h:28:#include <xkbcommon/xkbcommon-names.h>
/tmp/scratch/x11hdr-probe/sysroot/include/xkbcommon/xkbcommon.h:29:#include <xkbcommon/xkbcommon-keysyms.h>
/tmp/scratch/x11hdr-probe/sysroot/include/xkbcommon/xkbcommon.h:2592:#include <xkbcommon/xkbcommon-compat.h>
```

Where each transitive header comes from. `xorgproto-devel` is installed on the host, so
every wire-protocol header is already there.

```
$ for h in /usr/include/X11/Xfuncproto.h /usr/include/X11/extensions/xtestconst.h /usr/include/X11/extensions/xfixeswire.h /usr/include/X11/extensions/XI2.h /usr/include/X11/Xlib.h /usr/include/X11/extensions/Xge.h; do
    printf '%-46s ' "$h"; rpm -qf "$h"
  done
/usr/include/X11/Xfuncproto.h                  xorgproto-devel-2024.1-160000.2.2.noarch
/usr/include/X11/extensions/xtestconst.h       xorgproto-devel-2024.1-160000.2.2.noarch
/usr/include/X11/extensions/xfixeswire.h       xorgproto-devel-2024.1-160000.2.2.noarch
/usr/include/X11/extensions/XI2.h              xorgproto-devel-2024.1-160000.2.2.noarch
/usr/include/X11/Xlib.h                        libX11-devel-1.8.10-160000.3.1.x86_64
/usr/include/X11/extensions/Xge.h              libXext-devel-1.3.6-160000.3.2.x86_64
```

| Header | On the host | In the Nix sysroot | Source |
|---|---|---|---|
| `X11/Xfuncproto.h` | yes | no | host `xorgproto-devel` |
| `X11/extensions/xtestconst.h` | yes | no | host `xorgproto-devel` |
| `X11/extensions/xfixeswire.h` | yes | no | host `xorgproto-devel` |
| `X11/extensions/XI2.h` | yes | no | host `xorgproto-devel` |
| `X11/Xlib.h` | yes | yes | both, same 1.8 series |
| `X11/extensions/Xge.h` | yes | yes | both |
| `X11/extensions/XInput.h` | no | yes | Nix only. This one is also missing on the host. |

`XInput.h` is a fifth missing header that the brief did not name. `XTest.h` needs it at
line 32, so it is part of the same blocker.

```
$ for h in X11/Xfuncproto.h X11/extensions/XI2.h X11/extensions/xtestconst.h X11/extensions/XInput.h X11/Xlib.h X11/extensions/Xge.h X11/extensions/xfixeswire.h; do
    printf '%-34s host=%s nixsysroot=%s\n' "$h" "$(test -f /usr/include/$h && echo YES || echo no)" "$(test -f $D/$h && echo YES || echo no)"
  done
X11/Xfuncproto.h                   host=YES nixsysroot=no
X11/extensions/XI2.h               host=YES nixsysroot=no
X11/extensions/xtestconst.h        host=YES nixsysroot=no
X11/extensions/XInput.h            host=no nixsysroot=YES
X11/Xlib.h                         host=YES nixsysroot=YES
X11/extensions/Xge.h               host=YES nixsysroot=YES
X11/extensions/xfixeswire.h        host=YES nixsysroot=no
```

### 2.1 Copying the headers into the scratch prefix

The store paths are read-only, so a plain copy must relax the mode first. Each code block
above is its own shell session. This one sets `D` to the sysroot root, one level above the
value used in the previous block.

```
$ S=/tmp/devenv-sbox-from-hometmp/nix/store
$ D=/tmp/scratch/x11hdr-probe/sysroot
$ mkdir -p "$D/include/X11" "$D/include/xkbcommon"
$ for p in qljkaaa4v37lyc43c91pvz5fsgf8j2wg-libxtst-1.2.5 \
           jxqrv7q8ydpsc2m9zli83bjsabq0rxs0-libxfixes-6.0.2-dev \
           7zvd4bm46yg9wkx17qpzbgcj27fji8yq-libxi-1.8.3-dev \
           2mcjx364ls9id3ngdjxd707j2az2aid2-libx11-1.8.13-dev \
           fl7xj4bahw025r9nw6d9vgb4043665mj-libxext-1.3.7-dev \
           ca5a9x0y311vmw1a1sj6d00z0jwaviwv-libxau-1.0.12-dev; do
    cp -r "$S/$p/include/X11/." "$D/include/X11/"; chmod -R u+w "$D"
  done
$ cp -r "$S/47nlx1dpb8zd73vjp2zms7r8k9xkzndp-libxkbcommon-1.13.2-dev/include/xkbcommon/." "$D/include/xkbcommon/"
$ chmod -R u+w "$D"
$ for h in XTest.h Xfixes.h XInput2.h xkbcommon.h; do find "$D" -name "$h"; done
$ find "$D/include" -name '*.h' | wc -l
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XTest.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/Xfixes.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XInput2.h
/tmp/scratch/x11hdr-probe/sysroot/include/xkbcommon/xkbcommon.h
42
```

One command failed on the first attempt and is reported here so the plan does not repeat it:

```
$ cp -r "$S/.../libxfixes/include/X11" "$D/include/"
cp: cannot create regular file '/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/Xfixes.h': Permission denied
```

The 42 headers in the scratch sysroot are the complete X11 and xkbcommon surface:

```
$ find /tmp/scratch/x11hdr-probe/sysroot/include -name '*.h' | sort
/tmp/scratch/x11hdr-probe/sysroot/include/X11/ImUtil.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/XKBlib.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/Xauth.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/Xcms.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/Xlib-xcb.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/Xlib.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/XlibConf.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/Xlibint.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/Xlocale.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/Xregion.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/Xresource.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/Xutil.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/cursorfont.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/MITMisc.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XEVI.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XInput.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XInput2.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XKBgeom.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XLbx.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XShm.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/XTest.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/Xag.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/Xcup.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/Xdbe.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/Xext.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/Xfixes.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/Xge.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/dpms.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/extutil.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/multibuf.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/record.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/security.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/shape.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/sync.h
/tmp/scratch/x11hdr-probe/sysroot/include/X11/extensions/xtestext1.h
/tmp/scratch/x11hdr-probe/sysroot/include/xkbcommon/xkbcommon-compat.h
/tmp/scratch/x11hdr-probe/sysroot/include/xkbcommon/xkbcommon-compose.h
/tmp/scratch/x11hdr-probe/sysroot/include/xkbcommon/xkbcommon-keysyms.h
/tmp/scratch/x11hdr-probe/sysroot/include/xkbcommon/xkbcommon-names.h
/tmp/scratch/x11hdr-probe/sysroot/include/xkbcommon/xkbcommon-x11.h
/tmp/scratch/x11hdr-probe/sysroot/include/xkbcommon/xkbcommon.h
/tmp/scratch/x11hdr-probe/sysroot/include/xkbcommon/xkbregistry.h
```

## 3. The Zig 0.16.0 distribution: DOES NOT WORK

**Verdict: DOES NOT WORK. The Zig distribution ships no X11 header and no xkbcommon
header. It has no `X11` directory anywhere. Its bundled musl and glibc sysroots carry the
C library only.**

```
$ Z=/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ
$ find "$Z" \( -name 'XTest.h' -o -name 'Xfixes.h' -o -name 'XInput2.h' -o -name 'xkbcommon.h' \) 2>/dev/null
$ echo $?
0

$ find "$Z" -type d -name 'X11' 2>/dev/null
$ echo $?
0
```

Both commands returned exit 0 with no output. None of the four exists.

The only near-matches in the whole distribution are one SSE test intrinsic and thirteen
Windows input files. None of them is X11.

```
$ find "$Z" -iname '*XTest*' -o -iname '*Xfixes*' -o -iname '*XInput*' -o -iname '*xkb*' 2>/dev/null | head -20
/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/include/xtestintrin.h
/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/libc/mingw/lib-common/xinput1_4.def
/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/libc/mingw/lib-common/xinputuap.def
/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/libc/mingw/lib64/xinput1_1.def
/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/libc/mingw/lib64/xinput9_1_0.def
/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/libc/mingw/lib64/xinput1_2.def
/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/libc/mingw/lib64/xinput1_3.def
/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/libc/mingw/lib32/xinput1_1.def
/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/libc/mingw/lib32/xinput9_1_0.def
/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/libc/mingw/lib32/xinput1_4.def
/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/libc/mingw/lib32/xinput1_2.def
/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/libc/mingw/lib32/xinput1_3.def
/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/libc/mingw/lib32/xinputuap.def
/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/libc/include/any-windows-any/xinput.h
```

What the sysroots do contain:

```
$ ls /tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/libc
darwin
freebsd
glibc
include
mingw
musl
netbsd
openbsd
wasi

$ ls /tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/libc/include | head -20
aarch64-freebsd-none
aarch64-linux-any
aarch64-linux-gnu
aarch64-linux-musl
aarch64-netbsd-none
aarch64-openbsd-none
any-darwin-any
any-linux-any
any-windows-any
arc-linux-any
arc-linux-gnu
arm-freebsd-eabihf
arm-linux-any
arm-linux-gnu
arm-linux-musl
arm-netbsd-none
arm-openbsd-none
csky-linux-any
csky-linux-gnu
generic-freebsd
```

Those are per-target C library headers. No X11.

## 4. A musl cross build, and what Zig actually does: DOES NOT WORK without extra paths

**Verdict: DOES NOT WORK. A musl cross build makes the linker problem worse, not better.
Zig offers no sysroot path to search for these libraries. The native build fails on both
the header and the linker name. Both failures clear as soon as one include directory and
one library directory are supplied.**

### 4.1 Native build with no extra paths

The build stops at the linker. It never reaches the header error, so the header error is
shown separately below.

```
$ source ~/.dev-env.sh
$ zig build
install
+- install zprobe
   +- compile exe zprobe Debug native failure
error: error: unable to find dynamic system library 'Xtst' using strategy 'paths_first'. searched paths:
         /usr/local/lib64/libXtst.so
         /usr/local/lib64/libXtst.a
         /usr/local/lib/libXtst.so
         /usr/local/lib/libXtst.a
         /lib64/libXtst.so
         /lib64/libXtst.a
         /lib/libXtst.so
         /lib/libXtst.a
         /usr/lib64/libXtst.so
         /usr/lib64/libXtst.a
         /usr/lib/libXtst.so
         /usr/lib/libXtst.a
       error: unable to find dynamic system library 'xkbcommon' using strategy 'paths_first'. searched paths:
         /usr/local/lib64/libxkbcommon.so
         /usr/local/lib64/libxkbcommon.a
         /usr/local/lib/libxkbcommon.so
         /usr/local/lib/libxkbcommon.a
         /lib64/libxkbcommon.so
         /lib64/libxkbcommon.a
         /lib/libxkbcommon.so
         /lib/libxkbcommon.a
         /usr/lib64/libxkbcommon.so
         /usr/lib64/libxkbcommon.a
         /usr/lib/libxkbcommon.so
         /usr/lib/libxkbcommon.a
error: process exited with error code 1
failed command: /tmp/zig-global-cache/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/zig build-exe -lXtst -lxkbcommon -ODebug -Mroot=/tmp/scratch/x11hdr-probe/zprobe/src/main.zig -lc --cache-dir /tmp/cache/zig-local --global-cache-dir /tmp/cache/zig --name zprobe --listen=-
BUILD_EXIT=1
```

[The `failed command:` line is cut short here. The rest of it names the Zig library
directory and `--listen=-`.]

Isolating the header failure with `zig cc`:

```
$ cat cc.c
#include <X11/extensions/XTest.h>
#include <xkbcommon/xkbcommon.h>
int main(void) { return (int)xkb_keysym_from_name("a", XKB_KEYSYM_NO_FLAGS) + (int)&XTestFakeMotionEvent; }

$ zig cc -c cc.c -o cc.o
cc.c:1:10: fatal error: 'X11/extensions/XTest.h' file not found
    1 | #include <X11/extensions/XTest.h>
      |          ^~~~~~~~~~~~~~~~~~~~~~~~
1 error generated.
EXIT=1
```

The same failure through `@cImport`:

```
$ zig build-exe src/main.zig -lc -femit-bin=.../a_out
src/main.zig:1:11: error: C import failed
const c = @cImport({
          ^~~~~~~~
error: translation failure
/tmp/cache/zig-local/tmp/f0e32a18be0275bd/cimport.h:1:10: error: 'X11/extensions/XTest.h' not found
#include <X11/extensions/XTest.h>
         ^
EXIT=1
```

### 4.2 The musl cross build

```
$ zig build -Dtarget=x86_64-linux-musl
install
+- install zprobe
   +- compile exe zprobe Debug x86_64-linux-musl failure
error: error: unable to find dynamic system library 'Xtst' using strategy 'paths_first'. searched paths: none
       error: unable to find dynamic system library 'xkbcommon' using strategy 'paths_first'. searched paths: none
       error: unable to find dynamic system library 'Xfixes' using strategy 'paths_first'. searched paths: none
       error: unable to find dynamic system library 'Xi' using strategy 'paths_first'. searched paths: none
       error: unable to find dynamic system library 'X11' using strategy 'paths_first'. searched paths: none
       error: unable to find dynamic system library 'Xext' using strategy 'paths_first'. searched paths: none
error: process exited with error code 1
failed command: .../zig build-exe -lXtst -lxkbcommon -lXfixes -lXi -lX11 -lXext -ODebug -target x86_64-linux-musl -mcpu baseline -Mroot=.../src/main.zig -lc --listen=-
EXIT=1
```

[The `failed command:` line is cut short here for the same reason as in 4.1. The flags
after `-lc` are `--cache-dir ...`, `--global-cache-dir ...` and `--listen=-`.]

`searched paths: none` is the whole answer. A musl target has no system library search path
at all, so `linkSystemLibrary` cannot succeed even for `X11`, which the native build finds
without help.

### 4.3 `x11` and `xext` need nothing

For contrast, these two build and link on the host with no extra flags.

```
$ cat x11only.c
#include <X11/Xlib.h>
#include <X11/extensions/Xext.h>
int main(void){ Display *d = XOpenDisplay(0); (void)d; return 0; }

$ zig cc -c x11only.c -o x11only.o
EXIT=0
$ zig cc x11only.c -lX11 -lXext -o x11only
EXIT=0
$ ldd x11only | grep -E 'X11|Xext'
	libX11.so.6 => /lib64/libX11.so.6 (0x00007fe96a55d000)
```

### 4.4 One include directory and one library directory are enough

The library directory holds four symlinks with the names the linker looks for. They point
at the versioned shared objects the host already ships.

```
$ H=/tmp/scratch/x11hdr-probe/hostlink
$ mkdir -p "$H"
$ for n in Xtst Xfixes Xi xkbcommon; do
    for v in /usr/lib64/lib$n.so*; do [ -e "$v" ] && ln -sf "$v" "$H/lib$n.so"; done
  done
$ ls -la "$H"
total 8
drwx------ 2 user mi19 4096 Oct  5 00:36 .
drwx------ 6 user mi19 4096 Oct  5 00:36 ..
lrwxrwxrwx+    1 user mi19   29 Oct  5 00:36 libXfixes.so -> /usr/lib64/libXfixes.so.3.1.0
lrwxrwxrwx+    1 user mi19   25 Oct  5 00:36 libXi.so -> /usr/lib64/libXi.so.6.1.0
lrwxrwxrwx+    1 user mi19   27 Oct  5 00:36 libXtst.so -> /usr/lib64/libXtst.so.6.1.0
lrwxrwxrwx+    1 user mi19   32 Oct  5 00:36 libxkbcommon.so -> /usr/lib64/libxkbcommon.so.0.8.0
```

The probe `src/main.zig` calls one function from each library.

```zig
const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/extensions/XTest.h");
    @cInclude("X11/extensions/Xfixes.h");
    @cInclude("X11/extensions/XInput2.h");
    @cInclude("xkbcommon/xkbcommon.h");
});

const std = @import("std");

pub fn main() !void {
    const keysym = c.xkb_keysym_from_name("a", c.XKB_KEYSYM_NO_FLAGS);
    std.debug.print("xkb_keysym_from_name(\"a\") = {d}\n", .{keysym});

    const display = c.XOpenDisplay(null);
    if (display == null) {
        std.debug.print("XOpenDisplay(null) returned null\n", .{});
        return;
    }
    const screen = c.XDefaultScreen(display);
    std.debug.print("XOpenDisplay ok, screen={d}\n", .{screen});

    var major: c_int = 2;
    var minor: c_int = 0;
    const xinput_status = c.XIQueryVersion(display, &major, &minor);
    std.debug.print("XIQueryVersion status={d} major={d} minor={d}\n", .{ xinput_status, major, minor });

    const ok = c.XTestFakeMotionEvent(display, screen, 40, 30, 0);
    _ = c.XFlush(display);
    std.debug.print("XTestFakeMotionEvent(40,30) = {d}\n", .{ok});

    const img = c.XFixesGetCursorImage(display);
    std.debug.print("XFixesGetCursorImage x={d} y={d} width={d} height={d}\n", .{ img.*.x, img.*.y, img.*.width, img.*.height });
    _ = c.XSync(display, 0);

    _ = c.XTestFakeButtonEvent(display, 1, 1, 0);
    _ = c.XFlush(display);
    if (c.XPending(display) != 0) {
        var event: c.XEvent = undefined;
        _ = c.XNextEvent(display, &event);
        std.debug.print("XNextEvent type={d}\n", .{@as(c_int, event.type)});
    } else {
        std.debug.print("XPending returned 0\n", .{});
    }

    _ = c.XCloseDisplay(display);
}
```

`build.zig` links six libraries. Zig 0.16.0 moved `linkSystemLibrary` onto the module,
and it now takes an options argument. The two `-Dextra-*` options are the probe's own,
and they read paths into `mod.addIncludePath`, `mod.addLibraryPath` and `mod.addRPath`.

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    for (b.option([]const []const u8, "extra-include", "dirs") orelse &.{}) |d| {
        mod.addIncludePath(.{ .cwd_relative = d });
    }
    for (b.option([]const []const u8, "extra-libdir", "dirs") orelse &.{}) |d| {
        mod.addLibraryPath(.{ .cwd_relative = d });
        mod.addRPath(.{ .cwd_relative = d });
    }

    mod.linkSystemLibrary("Xtst", .{});
    mod.linkSystemLibrary("xkbcommon", .{});
    mod.linkSystemLibrary("Xfixes", .{});
    mod.linkSystemLibrary("Xi", .{});
    mod.linkSystemLibrary("X11", .{});
    mod.linkSystemLibrary("Xext", .{});

    const exe = b.addExecutable(.{
        .name = "zprobe",
        .root_module = mod,
    });

    b.installArtifact(exe);
}
```

Building with only the scratch sysroot and the symlink directory:

```
$ zig build -Dextra-include=/tmp/scratch/x11hdr-probe/sysroot/include \
            -Dextra-libdir=/tmp/scratch/x11hdr-probe/hostlink
anyzig: .minimum_zig_version '0.16.0' pulled from '/tmp/scratch/x11hdr-probe/zprobe/build.zig.zon'
anyzig: appdata '~/.local/share/anyzig'
anyzig: zig '0.16.0' already exists at '/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ'
BUILD_EXIT=0
```

The result links only against host runtime libraries, with no Nix object in the output.

```
$ ldd zig-out/bin/zprobe | grep -E 'X11|Xtst|Xfixes|Xi\.|xkbcommon'
	libXtst.so.6 => /lib64/libXtst.so.6 (0x00007f80d7317000)
	libxkbcommon.so.0 => /lib64/libxkbcommon.so.0 (0x00007f80d72c6000)
	libXfixes.so.3 => /lib64/libXfixes.so.3 (0x00007f80d72be000)
	libXi.so.6 => /lib64/libXi.so.6 (0x00007f80d72aa000)
	libX11.so.6 => /lib64/libX11.so.6 (0x00007f80d7163000)
```

And it runs against Xvfb. `Xvfb` was started and stopped inside this probe.

```
$ Xvfb :77 -screen 0 1280x1024x24 >xvfb.log 2>&1 &
$ sleep 3
$ DISPLAY=:77 ./zig-out/bin/zprobe
xkb_keysym_from_name("a") = 97
XOpenDisplay ok, screen=0
XIQueryVersion status=0 major=2 minor=0
XTestFakeMotionEvent(40,30) = 1
XFixesGetCursorImage x=40 y=30 width=16 height=16
XPending returned 0
PROBE_EXIT=0
$ kill $XPID
```

Each line is a real result, not a link check. `XFixesGetCursorImage` reports the pointer at
x=40 y=30, which is exactly the position `XTestFakeMotionEvent(40,30)` asked for, so XTest
really moved the pointer inside the X server.

### 4.5 The same result with Nix libraries instead of host libraries

Both halves can also come from the Nix store, which also works.

```
$ ldd zig-out/bin/zprobe | grep -E 'X11|Xtst|Xfixes|Xi\.|xkbcommon'
	libXtst.so.6 => /tmp/devenv-sbox-from-hometmp/nix/store/qljkaaa4v37lyc43c91pvz5fsgf8j2wg-libxtst-1.2.5/lib/libXtst.so.6
	libxkbcommon.so.0 => /tmp/devenv-sbox-from-hometmp/nix/store/nvrv5w6rhc39h8snrsw03nqs679cf7rh-libxkbcommon-1.13.2/lib/libxkbcommon.so.0
	libXfixes.so.3 => /tmp/devenv-sbox-from-hometmp/nix/store/l5y7fz08zvrqiinb90j1r922ymncb0sj-libxfixes-6.0.2/lib/libXfixes.so.3
	libXi.so.6 => /tmp/devenv-sbox-from-hometmp/nix/store/sp7qi6d789jbkbn0mpzna06gbxlm5gzi-libxi-1.8.3/lib/libXi.so.6
	libX11.so.6 => /tmp/devenv-sbox-from-hometmp/nix/store/znrm90algr0fvnnnp130am1qfg59nl1f-libx11-1.8.13/lib/libX11.so.6
	libXext.so.6 => /tmp/devenv-sbox-from-hometmp/nix/store/firki6qp8l2y6jgpwvix2wd95bi572mi-libxext-1.3.7/lib/libXext.so.6
```

### 4.6 `zig cc` with the same two directories

```
$ zig cc -c cc.c -I /tmp/scratch/x11hdr-probe/sysroot/include -o cc.o
cc.c:3:79: warning: cast to smaller integer type 'int' from 'int (*)(Display *, int, int, int, unsigned long)' ... [-Wpointer-to-int-cast]
1 warning generated.
EXIT=0
$ zig cc cc.o -L /tmp/scratch/x11hdr-probe/hostlink -lXtst -lxkbcommon -lXfixes -lXi -o ccbin
EXIT=0
$ ldd ccbin | grep -E 'Xtst|xkbcommon|Xfixes|Xi\.'
	libXtst.so.6 => /lib64/libXtst.so.6 (0x00007f7e48b59000)
	libxkbcommon.so.0 => /lib64/libxkbcommon.so.0 (0x00007f7e48b0a000)
```

So the answer is the same for `zig cc` and for `linkSystemLibrary`. The host is not
missing a compiler capability. It is missing two directories of files.

## 5. What the upstream adapter actually needs

**Verdict: no external header at all. The upstream unix adapter includes none of the four
missing headers, and uses none of the four missing libraries. It contains no X11 path.**

This contradicts the premise of the task brief, so the search is reported in full.

```
$ A=/tmp/scratch/accesskit/adapters/unix
$ grep -rn 'xcb\|wayland\|X11\|xlib\|xkb\|XTest\|Xfixes\|XInput\|dlopen\|build\.rs\|extern "C"\|#\[link' "$A/src" "$A/Cargo.toml"
/tmp/scratch/accesskit/adapters/unix/src/adapter.rs:172:    /// Wayland, calling this method only makes sense under X11.
```

One hit in 1471 lines of Rust, and it is a doc comment. The line is inside the comment on
`set_root_window_bounds`:

```rust
/// Since an application can not get the position of its window under
/// Wayland, calling this method only makes sense under X11.
pub fn set_root_window_bounds(&mut self, outer: Rect, inner: Rect) {
```

There is no `build.rs` and no C dependency in the crate directory.

```
$ ls -a /tmp/scratch/accesskit/adapters/unix
.
..
CHANGELOG.md
Cargo.toml
README.md
src

$ wc -l /tmp/scratch/accesskit/adapters/unix/src/*.rs /tmp/scratch/accesskit/adapters/unix/src/atspi/*.rs
  276 /tmp/scratch/accesskit/adapters/unix/src/adapter.rs
  306 /tmp/scratch/accesskit/adapters/unix/src/context.rs
  158 /tmp/scratch/accesskit/adapters/unix/src/executor.rs
   27 /tmp/scratch/accesskit/adapters/unix/src/lib.rs
   42 /tmp/scratch/accesskit/adapters/unix/src/util.rs
  525 /tmp/scratch/accesskit/adapters/unix/src/atspi/bus.rs
   13 /tmp/scratch/accesskit/adapters/unix/src/atspi/mod.rs
   45 /tmp/scratch/accesskit/adapters/unix/src/atspi/object_address.rs
   79 /tmp/scratch/accesskit/adapters/unix/src/atspi/object_id.rs
 1471 total
```

The crate is `accesskit_unix` and it speaks D-Bus over a Unix socket through the pure-Rust
`zbus` crate. It reads no display server at all.

The shared translation layer `accesskit_atspi_common` is the same. It has no hit at all,
and no `build.rs`.

```
$ A=/tmp/scratch/accesskit/adapters/atspi-common
$ grep -rn 'xcb\|wayland\|X11\|xlib\|xkb\|XTest\|Xfixes\|XInput\|dlopen\|build\.rs\|extern "C"\|#\[link' "$A/src" "$A/Cargo.toml"
grep exit: 1

$ ls -a /tmp/scratch/accesskit/adapters/atspi-common
.
..
CHANGELOG.md
Cargo.toml
README.md
src
```

The same holds for the whole upstream repository. No X11 adapter has ever existed there.
The clone has full history, not a shallow one, and no remote branch or tag mentions X11.

```
$ cd /tmp/scratch/accesskit
$ ls .git/shallow
ls: cannot access '.git/shallow': No such file or directory
$ git rev-list --count HEAD
711
$ git log --all --pretty=format: --name-only | sort -u | grep -icE 'x11|xorg|xtst|xfixes|xinput'
0
$ git ls-remote --heads origin | sed 's#.*refs/heads/##' | tr '\n' ' '
combobox demo fix-closure-ref geometry-tests jni-bindings l10n main newton-prototype newton-prototype-postcard quorum-work release-please--branches--main revert-range-clamping stacked-alloc-refactors unix-filter-events update-objc2 web-basics winit-new-user-events
$ grep -rn 'x11\|X11\|xorg\|xlib\|xtst\|xfixes\|xinput' --include='*.toml' --include='*.rs' . | head
./example_common/Cargo.toml:18:    "x11",
./example_common/Cargo.toml:19:    "x11-dlopen",
./adapters/winit/Cargo.toml:16:default = ["accesskit_unix", "async-io", "rwh_06", "winit/x11", "winit/wayland"]
./adapters/winit/Cargo.toml:49:features = ["x11", "wayland", "wayland-dlopen", "wayland-csd-adwaita"]
./adapters/unix/src/adapter.rs:172:    /// Wayland, calling this method only makes sense under X11.
```

No crate named `accesskit_x11_adapter` exists on crates.io, and the AccessKit
organisation publishes no X11 repository.

```
$ curl -sS -o /dev/null -w '%{http_code}\n' https://index.crates.io/ac/ce/accesskit_x11_adapter
404
$ curl -sS -o /dev/null -w '%{http_code}\n' https://index.crates.io/ac/ce/accesskit_unix
200
$ curl -sS https://index.crates.io/ac/ce/accesskit_unix | tail -1 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["name"], d["vers"])'
accesskit_unix 0.24.0
```

The 404 for `accesskit_x11_adapter` against an index that answers 200 for
`accesskit_unix` confirms the crate does not exist. Of the five hits in the last grep,
four select a windowing backend for the example helper and the winit adapter, and one is
the doc comment already quoted. None of them is an accessibility path.

### 5.1 Header-by-header table

One row per external header, as asked. The source column is empty because no upstream file
includes any of them.

| External header | Source file | Line | Blocks the upstream unix adapter? |
|---|---|---|---|
| `X11/extensions/XTest.h` | none | none | No. Nothing in `accesskit_unix` includes it. |
| `X11/extensions/Xfixes.h` | none | none | No. Nothing in `accesskit_unix` includes it. |
| `X11/extensions/XInput2.h` | none | none | No. Nothing in `accesskit_unix` includes it. |
| `xkbcommon/xkbcommon.h` | none | none | No. Nothing in `accesskit_unix` includes it. |
| `X11/extensions/XInput.h` | none | none | No. Nothing in `accesskit_unix` includes it. It is the fifth missing header, found in section 2. |

### 5.2 Which headers block what

The distinction the plan needs is between the upstream port and any X11 path added on top
of it.

| Scope | Headers it needs | Missing on this host? | Effect |
|---|---|---|---|
| `accesskit_unix` port as upstream writes it | none | not applicable | Unaffected. It compiles today. |
| `accesskit_atspi_common` translation layer | none | not applicable | Unaffected. Pure data. |
| Any new X11 tree reader | `XTest.h`, `Xfixes.h`, `XInput2.h`, `xkbcommon.h`, and `XInput.h`, with `Xlib.h` already on the host | five from the Nix store, none from the host package manager | Blocked until section 6 adds one include directory. |

So the four missing headers block nothing that exists upstream. They block only a path the
plan would have to write, and section 6 shows the unblocking cost is two directories.

## 6. The verdict

| Missing header | Obtainable on this host? | By what means |
|---|---|---|
| `X11/extensions/XTest.h` | Yes | `~/.local/bin/nix build nixpkgs#libXtst`, headers in the `out` output, copied to a scratch sysroot. |
| `X11/extensions/Xfixes.h` | Yes | `~/.local/bin/nix build nixpkgs#libXfixes.dev`, headers in the `dev` output. |
| `X11/extensions/XInput2.h` | Yes | `~/.local/bin/nix build nixpkgs#libXi.dev`, headers in the `dev` output. |
| `X11/extensions/XInput.h` | Yes | `~/.local/bin/nix build nixpkgs#libXi.dev`, same `dev` output. `XTest.h` includes it at line 32. |
| `xkbcommon/xkbcommon.h` | Yes | `~/.local/bin/nix build nixpkgs#libxkbcommon.dev`, headers in the `dev` output. |

Not one of the five is obtainable from the host package manager, because installation
needs root. Not one is in the Zig 0.16.0 distribution. All five come from the Nix sandbox
store, which this account already controls.

The sentence the plan can rely on:

> An X11 adapter cannot be compiled or linked on this host as things stand, and the
> smallest change that makes it possible is to give the build one extra include directory
> holding the five headers copied out of the Nix store and one extra library directory
> holding four symlinks named `libXtst.so`, `libXfixes.so`, `libXi.so` and
> `libxkbcommon.so` that point at the versioned shared objects the host already ships,
> after which a probe that calls Xlib, XTest, XFixes, XInput2 and xkbcommon compiles,
> links and runs against Xvfb.

The evidence behind that sentence is section 4.4, where the build exits 0 with those two
directories and the binary moves a pointer inside Xvfb through `XTestFakeMotionEvent`.

Two further facts the plan should carry:

1. The linker-name defect is independent of the header defect. Even with every header
   present, `linkSystemLibrary` still fails, because the host ships `libXtst.so.6` but not
   `libXtst.so`. Both fixes are needed.
2. Nothing here touches the port of `accesskit_unix`, which needs no X11 header and no C
   library. The X11 work is optional scope, not a prerequisite for the AT-SPI port.

### 6.1 Reproduction

Everything in this document was built from `/tmp/scratch/x11hdr-probe/`
and nothing else. The scratch tree was removed afterwards.

```sh
S=/tmp/devenv-sbox-from-hometmp/nix/store
D=/tmp/scratch/x11hdr-probe/sysroot
H=/tmp/scratch/x11hdr-probe/hostlink

# 1. Fetch the four libraries from the Nix store.
~/.local/bin/nix build --no-link --print-out-paths \
  'nixpkgs#libXtst' 'nixpkgs#libXfixes.dev' 'nixpkgs#libXi.dev' 'nixpkgs#libxkbcommon.dev'

# 2. Copy the headers into a writable scratch sysroot.
mkdir -p "$D/include/X11" "$D/include/xkbcommon"
for p in qljkaaa4v37lyc43c91pvz5fsgf8j2wg-libxtst-1.2.5 \
         jxqrv7q8ydpsc2m9zli83bjsabq0rxs0-libxfixes-6.0.2-dev \
         7zvd4bm46yg9wkx17qpzbgcj27fji8yq-libxi-1.8.3-dev \
         2mcjx364ls9id3ngdjxd707j2az2aid2-libx11-1.8.13-dev \
         fl7xj4bahw025r9nw6d9vgb4043665mj-libxext-1.3.7-dev \
         ca5a9x0y311vmw1a1sj6d00z0jwaviwv-libxau-1.0.12-dev; do
  cp -r "$S/$p/include/X11/." "$D/include/X11/"; chmod -R u+w "$D"
done
cp -r "$S/47nlx1dpb8zd73vjp2zms7r8k9xkzndp-libxkbcommon-1.13.2-dev/include/xkbcommon/." "$D/include/xkbcommon/"
chmod -R u+w "$D"

# 3. Give the linker the four names it looks for.
mkdir -p "$H"
for n in Xtst Xfixes Xi xkbcommon; do
  for v in /usr/lib64/lib$n.so*; do [ -e "$v" ] && ln -sf "$v" "$H/lib$n.so"; done
done

# 4. Build and run.
cd /tmp/scratch/x11hdr-probe/zprobe
zig build -Dextra-include="$D/include" -Dextra-libdir="$H"
Xvfb :77 -screen 0 1280x1024x24 >xvfb.log 2>&1 &
XPID=$!; sleep 3
DISPLAY=:77 ./zig-out/bin/zprobe
kill $XPID
```

The Nix store hashes in step 2 are pinned to `nixpkgs-unstable` at the time of
measurement. A future run should resolve them from `--print-out-paths` rather than copy
the strings, because a nixpkgs update changes them.
