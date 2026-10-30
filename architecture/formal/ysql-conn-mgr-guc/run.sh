#!/usr/bin/env bash
# Parse GucSession.tla with SANY, then model-check it with TLC.
# Usage: ./run.sh [cfg] [extra TLC args...]   (default cfg: GucSession.cfg)
set -euo pipefail
cd "$(dirname "$0")"
JAVA=${JAVA:-/usr/lib/jvm/zulu-17.jdk/bin/java}
JAR=${TLA_JAR:-$HOME/tools/tla/tla2tools.jar}
CFG=${1:-GucSession.cfg}
shift || true
META=${TLC_META:-${TMPDIR:-/tmp}/tlc-states}
mkdir -p "$META"
"$JAVA" -Djava.io.tmpdir="$META" -cp "$JAR" tla2sany.SANY GucSession.tla
"$JAVA" -Djava.io.tmpdir="$META" -XX:+UseParallelGC -Xmx8g -cp "$JAR" tlc2.TLC -workers auto -noGenerateSpecTE \
    -metadir "$META/$(basename "$CFG" .cfg)-$$" -cleanup \
    -config "$CFG" "$@" GucSession.tla
