#!/usr/bin/env bash
# Translate a PlusCal spec and model-check it with TLC.
#
#   ./formal/check.sh OpLogSync                  # uses OpLogSync.cfg
#   ./formal/check.sh OpLogSync OpLogSync_shared # uses OpLogSync_shared.cfg
#
# Exit 0 = TLC found no violation. Non-zero = violation or tooling error.
# A non-zero exit is an EXPECTED outcome for the falsification configs;
# see formal/README.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="${1:?usage: check.sh <SpecName> [ConfigName]}"
CFG="${2:-$SPEC}"
JAR="$HERE/tools/tla2tools.jar"
JAR_URL="https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar"

# Homebrew's `openjdk` formula is keg-only: it is deliberately NOT symlinked
# into the PATH, and /usr/bin/java will not find it. Resolving it here (rather
# than asking every caller to export JAVA_HOME) is what lets this run with no
# sudo — the `temurin` cask would need a password to install.
find_java() {
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
        echo "$JAVA_HOME/bin/java"; return 0
    fi
    if command -v java >/dev/null 2>&1 && java -version >/dev/null 2>&1; then
        command -v java; return 0
    fi
    for candidate in /opt/homebrew/opt/openjdk/bin/java \
                     /usr/local/opt/openjdk/bin/java; do
        [ -x "$candidate" ] && { echo "$candidate"; return 0; }
    done
    if command -v brew >/dev/null 2>&1; then
        candidate="$(brew --prefix openjdk 2>/dev/null)/bin/java"
        [ -x "$candidate" ] && { echo "$candidate"; return 0; }
    fi
    return 1
}

if ! JAVA="$(find_java)"; then
    echo "error: no Java runtime. Run: brew install openjdk" >&2
    exit 127
fi

if [ ! -f "$JAR" ]; then
    echo "fetching tla2tools.jar ..."
    mkdir -p "$HERE/tools"
    curl -fsSL "$JAR_URL" -o "$JAR"
fi

cd "$HERE"

# PlusCal -> TLA+. Rewrites the .tla in place between the BEGIN/END
# TRANSLATION markers. Skipped for specs with no PlusCal block.
if grep -q '^(\*--algorithm' "$SPEC.tla"; then
    echo "== translating PlusCal =="
    "$JAVA" -cp "$JAR" pcal.trans "$SPEC.tla"
fi

echo "== TLC: $SPEC.tla against $CFG.cfg =="
"$JAVA" -XX:+UseParallelGC -cp "$JAR" tlc2.TLC \
    -config "$CFG.cfg" -workers auto -cleanup "$SPEC.tla"
