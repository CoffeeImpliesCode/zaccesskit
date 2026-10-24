{ pkgs, ... }:
{
  packages = [ pkgs.git pkgs.pkg-config ];

  enterShell = ''
    if [ "$(zig version)" != "0.17.0" ]; then
      echo "zaccesskit requires Zig 0.17.0 on PATH" >&2
      return 1
    fi
  '';

  enterTest = ''
    zig build test
  '';
}
