#!/bin/sh
# Compiles the C consumer against `include/zaccesskit.h` and reports what the
# header lets a C program do.
#
# This does not link. `src/capi/` is being written in parallel, so every
# `accesskit_` symbol is undefined at link time. That is the expected state, not
# a failure of this script, and this script does not pretend otherwise: it stops
# at `-c` and says so in its own section at the end.
#
# What it checks is the property that belongs to the header alone, that a C
# program can spell and use the whole surface.
#
# C11 is the mode the header claims and the mode it is clean in, so C11 is the
# gate. C99 and C++17 are measured on the header alone, because the diagnostic
# counts the header states about itself are counts for the header, not for a
# consumer. Those are recorded, not gated.
#
# Usage: test/c_consumer/check.sh
# Exit:  0 if every gate is clean, 1 otherwise.

set -u

# English diagnostics, so the warning count does not depend on the caller's
# locale.
LC_ALL=C
export LC_ALL

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../.." && pwd)
include="$repo/include"
header="$include/zaccesskit.h"

# The counts the header states about itself, repeated here so that a drift
# between the header and this check is a failure rather than a stale comment.
want_linux_functions=446
want_header_functions=498
want_action_data_arms=8
want_c99_diagnostics=10
want_cxx_diagnostics_low=8
want_cxx_diagnostics_high=16

cc_list=${CC_LIST:-"gcc clang cc"}
cxx_list=${CXX_LIST:-"g++ clang++"}

work=${TMPDIR:-/tmp}/zaccesskit-c-consumer.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT HUP INT TERM

status=0

# Notes and failures go to stderr, so a helper can return its count on stdout
# without the count picking up the commentary.
note() { printf '%s\n' "$*" >&2; }
fail() { printf 'FAIL %s\n' "$*" >&2; status=1; }

# compile_count <compiler> <std> <language> <source> <flags...>
# Prints the number of warnings the compile produced, or -1 if it failed.
compile_count() {
    cc=$1
    std=$2
    lang=$3
    source=$4
    shift 4
    log="$work/$(basename "$cc").$std.$lang.log"
    if "$cc" -std="$std" -x "$lang" -I"$include" -I"$here" "$@" \
        -c "$source" -o "$work/out.o" >"$log" 2>&1; then
        count=$(grep -c 'warning:' "$log" || true)
        printf '%s\n' "${count:-0}"
        return 0
    fi
    printf '%s\n' -1
    return 1
}

# --------------------------------------------------------------------------
note "== C11 gate: the whole consumer, -Wall -Wextra -Wpedantic, no other flag =="
for cc in $cc_list; do
    command -v "$cc" >/dev/null 2>&1 || { note "  $cc not installed, skipped"; continue; }
    n=$(compile_count "$cc" c11 c "$here/consumer.c" -Wall -Wextra -Wpedantic)
    if [ "$n" = "-1" ]; then
        fail "$cc: consumer.c does not compile as C11 against the header"
        sed -n '1,40p' "$work/$(basename "$cc").c11.c.log" | sed 's/^/    /' >&2
    else
        note "  $cc -std=c11 -Wall -Wextra -Wpedantic: compiled, $n warning(s)"
        [ "$n" = "0" ] || fail "$cc: the C11 gate produced $n warning(s)"
    fi
done

# --------------------------------------------------------------------------
note ""
note "== C17 and C2x, the same source, same flags =="
for cc in $cc_list; do
    command -v "$cc" >/dev/null 2>&1 || continue
    for std in c17 c23; do
        n=$(compile_count "$cc" "$std" c "$here/consumer.c" -Wall -Wextra -Wpedantic)
        if [ "$n" = "-1" ]; then
            note "  $cc -std=$std: does not compile"
            fail "$cc: the consumer must also compile as $std"
        else
            note "  $cc -std=$std: compiled, $n warning(s)"
            [ "$n" = "0" ] || fail "$cc: the $std gate produced $n warning(s)"
        fi
    done
done

# --------------------------------------------------------------------------
note ""
note "== the header on its own, in the modes it states diagnostic counts for =="
note "   Measured on the header, not on the consumer: the counts the header"
note "   documents are counts for the header. The header names its source"
note "   language C11 and says it is clean there."
printf '#include "zaccesskit.h"\nint main(void) { return 0; }\n' >"$work/header_only.c"
for cc in $cc_list; do
    command -v "$cc" >/dev/null 2>&1 || continue
    n=$(compile_count "$cc" c11 c "$work/header_only.c" -Wall -Wextra -Wpedantic)
    if [ "$n" = "0" ]; then
        note "  $cc -std=c11: the header alone is clean, as it claims"
    else
        fail "$cc: the header alone gives $n warning(s) in C11, the header says 0"
    fi
    n=$(compile_count "$cc" c99 c "$work/header_only.c" -Wall -Wextra -Wpedantic)
    note "  $cc -std=c99: $n diagnostic(s); the header states $want_c99_diagnostics"
    [ "$n" = "$want_c99_diagnostics" ] ||
        note "     (recorded, not gated: another compiler may report differently)"
done
for cxx in $cxx_list; do
    command -v "$cxx" >/dev/null 2>&1 || { note "  $cxx not installed, skipped"; continue; }
    # `-Wgnu-anonymous-struct` is the name clang gives the extension. g++
    # reports the same construct under `-Wpedantic`, which is already on, and
    # rejects the clang spelling outright.
    case $cxx in
    *clang*) extra=-Wgnu-anonymous-struct ;;
    *) extra= ;;
    esac
    n=$(compile_count "$cxx" c++17 c++ "$work/header_only.c" -Wall -Wextra \
        -Wpedantic $extra)
    if [ "$n" = "-1" ]; then
        fail "$cxx: the header does not compile as C++17"
        sed -n '1,20p' "$work/$(basename "$cxx").c++17.c++.log" | sed 's/^/    /' >&2
    else
        note "  $cxx -std=c++17: $n diagnostic(s); the header states"
        note "     $want_cxx_diagnostics_low to $want_cxx_diagnostics_high"
    fi
done

# --------------------------------------------------------------------------
note ""
note "== the declaration census in surface.h against the header =="

# The declarations this target sees. Preprocess the header, then take every
# distinct lowercase accesskit_ name immediately followed by an open parenthesis.
# A function-pointer typedef spells its own name inside parentheses, so the four
# callback typedefs do not match and the count is the number of functions, which
# is exactly what surface.h covers.
pre_cc=$(command -v gcc || command -v clang || command -v cc || true)
if [ -n "$pre_cc" ]; then
    printf '#include "zaccesskit.h"\n' >"$work/inc.c"
    if "$pre_cc" -std=c11 -E -P -I"$include" "$work/inc.c" >"$work/inc.i" 2>/dev/null; then
        visible=$(tr -s ' \t\n' ' ' <"$work/inc.i" |
            grep -o '\baccesskit_[a-z0-9_]* *(' | tr -d ' (' | sort -u | wc -l)
        visible=$(printf '%s' "$visible" | tr -d ' ')
        note "  declarations the header makes visible here: $visible"
        [ "$visible" = "$want_linux_functions" ] ||
            fail "the header exposes $visible declarations, surface.h covers $want_linux_functions"
    else
        fail "could not preprocess the header"
    fi
else
    fail "no C preprocessor found, so the census was not checked"
fi

# The total across every platform guard. Comments and preprocessor lines are
# dropped, the remaining declarations are joined, and each one that names an
# accesskit_ function and is not a typedef or an enum is counted.
total=$(awk '
function flush(   p) {
    if (cur == "") { return }
    p = cur
    gsub(/[ \t\r\n]+/, " ", p)
    sub(/^ /, "", p)
    if (p ~ /accesskit_[a-z0-9_]+ *\(/ && p !~ /^typedef/ && p !~ /^enum/) { count++ }
    cur = ""
}
BEGIN { incomment = 0; count = 0; cur = "" }
/^[ \t]*\/\*/ { incomment = 1 }
{
    line = $0
    if (incomment) {
        if (line ~ /\*\//) { incomment = 0; line = "" } else { line = "" }
    }
    gsub(/^[ \t]+/, "", line)
    gsub(/[ \t]+$/, "", line)
    if (line == "") { next }
    if (line ~ /^#/) { next }
    cur = cur " " line
    if (line ~ /;$/) { flush() }
}
END { flush(); print count + 0 }
' "$header")
note "  functions declared across every platform guard: $total (the header states $want_header_functions)"
[ "$total" = "$want_header_functions" ] ||
    fail "the header declares $total functions, the check expects $want_header_functions"

covered=$(grep -c '^ *[A-Za-z_].*(\*[a-z0-9_]*)(.*);$' "$here/surface.h" || true)
covered=$(printf '%s' "$covered" | tr -d ' ')
note "  typed function-pointer members in surface.h: $covered"
[ "$covered" = "$want_linux_functions" ] ||
    fail "surface.h has $covered members, expected $want_linux_functions"

arms=$(sed -n '/typedef struct accesskit_action_data {/,/} accesskit_action_data;/p' "$header" |
    grep -c '^ *struct {$' || true)
note "  anonymous struct arms in accesskit_action_data: $arms (the header states $want_action_data_arms)"
[ "$arms" = "$want_action_data_arms" ] ||
    fail "accesskit_action_data has $arms anonymous arms, expected $want_action_data_arms"

# --------------------------------------------------------------------------
note ""
note "== linking =="
note "  not attempted and not claimed. src/capi/ is still being written, so"
note "  every accesskit_ symbol this program names is undefined. The gates above"
note "  are about the header, and the header is a compile-time contract."

note ""
if [ "$status" -eq 0 ]; then
    note "RESULT: every gate clean"
else
    note "RESULT: at least one gate failed"
fi
exit "$status"