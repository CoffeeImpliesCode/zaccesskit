{ pkgs, lib, config, inputs, ... }:

let
  # Zig 0.16.0 cannot keep its caches on a network filesystem: the package
  # unpacker mis-stats the files it writes and reports them as "illegal file
  # type 'unknown'", and the cache-rename path panics on an EINVAL from
  # `access`. Identical sources build cleanly on local disk, so every cache
  # lives there and the build root points at it.
  #
  # This checkout is under $HOME on NFS, so the default resolves to
  # $XDG_CACHE_HOME/zaccesskit. `~/.dev-env.sh` points XDG_CACHE_HOME at the
  # host scratch mount, which is local disk. ZACCESKIT_CACHE_ROOT wins over
  # that; set it explicitly when the XDG default is not local.
  cacheRoot =
    let
      zaccesskitCacheRoot = builtins.getEnv "ZACCESKIT_CACHE_ROOT";
      xdgCacheHome = builtins.getEnv "XDG_CACHE_HOME";
    in
    if zaccesskitCacheRoot != "" then
      zaccesskitCacheRoot
    else if xdgCacheHome != "" then
      "${xdgCacheHome}/zaccesskit"
    else
      "${builtins.getEnv "HOME"}/.cache/zaccesskit-zig";
in
{
  packages = [
    pkgs.git
    # The port's C half builds against the distribution's toolkit headers and
    # links with `zig cc`, which brings its own libc, so no separate C compiler
    # package is needed. pkg-config comes from the host stdenv; it is listed
    # only so a missing host tool fails here instead of mid-build.
    pkgs.pkg-config
  ];

  # A build that dies holding a global-cache manifest wedges every later build
  # wanting the same cache, so it is per-project and off the checkout's
  # filesystem.
  env.ZIG_GLOBAL_CACHE_DIR = "${cacheRoot}/global";

  # The house gate otherwise inherits the shared host cache. Keep this
  # project's build products and cross-test evidence with its own caches.
  env.GATE_CACHE_DIR = "${cacheRoot}/build";
  env.GATE_CROSS_OUTPUT = "${cacheRoot}/cross-test";

  # Keep all source checks enabled. Exclude generated caches at any depth.
  env.GATE_EXCLUDE = "/[.]zig-cache/ /zig-out/ /zig-cache/ /.jj/ /devenv/ /.direnv/";

  enterShell = ''
    # Create this project's cache and install targets before linking the build root.
    mkdir -p -- "${cacheRoot}/build" "${cacheRoot}/pkg" "${cacheRoot}/install" "$ZIG_GLOBAL_CACHE_DIR"

    # `.zig-cache`, `zig-pkg`, and `zig-out` must be symlinks to local disk. A real
    # directory on a network filesystem is the failure this guards against,
    # so say so rather than silently moving a populated cache.
    for d in .zig-cache zig-pkg zig-out; do
      if [ -e "$d" ] && [ ! -L "$d" ]; then
        echo "zaccesskit: $PWD/$d is a real directory; Zig 0.16.0 cannot build here." >&2
        echo "zaccesskit: remove it and let devenv link it to ${cacheRoot}." >&2
      else
        case $d in
          .zig-cache) ln -sfn "${cacheRoot}/build" "$d" ;;
          zig-pkg) ln -sfn "${cacheRoot}/pkg" "$d" ;;
          zig-out) ln -sfn "${cacheRoot}/install" "$d" ;;
        esac
      fi
    done
  '';

  # The gate owns its stage order. zbc errors fail even with ZBC_STRICT=0;
  # ZBC_STRICT=1 also makes its warnings fail. Tests cover both safety modes.
  tasks."gate:zaccesskit".exec = "zig-gate";
  tasks."gate:zaccesskit".description = "Run the house gate, including analysers and the project cross-test matrix";

  enterTest = ''
    zig version
    zig-gate
  '';
}
