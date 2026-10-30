#!/usr/bin/env bash
# Model-check GucVersioning.tla.
#
#   ./run-versioning.sh                 # safety matrix: 3 strategies x 2 propagations
#   ./run-versioning.sh liveness        # P11/P11b/P11c at the reduced liveness bound
#   ./run-versioning.sh one STRATEGY PROPAGATION [KEY=VALUE ...] [-- PROPS...]
#
# KEY=VALUE overrides any CONSTANT line of GucVersioning.cfg (e.g. NODES='{"n1"}',
# STALE_READS=TRUE, AUTH='"backend"', TTL='"zero"'). Logs go to $OUT (default
# ./tlc-out). Each run checks one property at a time so every violation is
# reported, not just the first.
set -euo pipefail
cd "$(dirname "$0")"

JAVA=${JAVA:-/usr/lib/jvm/zulu-17.jdk/bin/java}
JAR=${JAR:-$HOME/tools/tla/tla2tools.jar}
OUT=${OUT:-$PWD/tlc-out}
META=${META:-${TMPDIR:-/tmp}/gucversioning-meta}
mkdir -p "$OUT" "$META"

SAFETY_INV=(P5 P5x)
SAFETY_PROP=(P10 P10d P12 FR1a FR1s FR1b FR1c P13)

# run_one TAG STRATEGY PROPAGATION "KEY=VAL ..." KIND NAME
run_one() {
  local tag=$1 strat=$2 prop=$3 overrides=$4 kind=$5 name=$6
  local cfg="$OUT/$tag-$name.cfg" log="$OUT/$tag-$name.log"
  sed -e "s/^\(\s*STRATEGY = \).*/\1\"$strat\"/" \
      -e "s/^\(\s*PROPAGATION = \).*/\1\"$prop\"/" \
      -e '/^INVARIANTS/,$d' GucVersioning.cfg > "$cfg"
  local kv
  for kv in $overrides; do
    local k=${kv%%=*} v=${kv#*=}
    sed -i "s/^\(\s*$k = \).*/\1$v/" "$cfg"
  done
  if [[ $kind == live ]]; then
    sed -i 's/^SPECIFICATION Spec$/SPECIFICATION FairSpec/' "$cfg"
    printf 'INVARIANTS\n    TypeOK\nPROPERTIES\n    %s\nCHECK_DEADLOCK FALSE\n' "$name" >> "$cfg"
  elif [[ $kind == inv ]]; then
    printf 'INVARIANTS\n    TypeOK\n    %s\nCHECK_DEADLOCK FALSE\n' "$name" >> "$cfg"
  else
    printf 'INVARIANTS\n    TypeOK\nPROPERTIES\n    %s\nCHECK_DEADLOCK FALSE\n' "$name" >> "$cfg"
  fi
  local start end
  start=$(date +%s)
  "$JAVA" -XX:+UseParallelGC -Xmx8g -cp "$JAR" tlc2.TLC -workers auto -noGenerateSpecTE \
    -metadir "$META/$tag-$name" -config "$cfg" GucVersioning.tla > "$log" 2>&1 || true
  end=$(date +%s)
  local verdict=PASS
  grep -qE "is violated|Error:" "$log" && verdict=FAIL
  local states
  states=$(grep -oE "[0-9]+ states generated, [0-9]+ distinct states" "$log" | tail -1 || true)
  printf '%-34s %-6s %-4s %5ss  %s\n' "$tag" "$name" "$verdict" "$((end - start))" "$states"
}

matrix() {
  local s p n
  for s in fluctuating gradual connection_static; do
    for p in on_read pushed; do
      for n in "${SAFETY_INV[@]}"; do run_one "$s-$p" "$s" "$p" "" inv "$n"; done
      for n in "${SAFETY_PROP[@]}"; do run_one "$s-$p" "$s" "$p" "" prop "$n"; done
    done
  done
}

liveness() {
  # Reduced bound: TLC liveness checking is far slower than safety.
  local lb='MAXSTMTS=2 MAXALTER=1'
  local lb2='MAXSTMTS=1 MAXALTER=1'
  local s p n
  for s in gradual connection_static fluctuating; do
    for p in on_read pushed; do
      for n in P11 P11b P11c; do
        run_one "live1n-$s-$p" "$s" "$p" "NODES={\"n1\"} $lb" live "$n"
        run_one "live2n-$s-$p" "$s" "$p" "$lb2" live "$n"
      done
    done
  done
}

case ${1:-matrix} in
  matrix) matrix ;;
  liveness) liveness ;;
  one)
    shift; strat=$1 prop=$2; shift 2
    ov=""; while [[ $# -gt 0 && $1 != -- ]]; do ov="$ov $1"; shift; done
    [[ ${1:-} == -- ]] && shift
    tag="$strat-$prop$(echo "$ov" | tr -d ' {}"' | tr '=,' '_-')"
    for n in "${@:-P5 P10}"; do
      case $n in
        P5|P5x) run_one "$tag" "$strat" "$prop" "$ov" inv "$n" ;;
        P11|P11b|P11c) run_one "$tag" "$strat" "$prop" "$ov" live "$n" ;;
        *) run_one "$tag" "$strat" "$prop" "$ov" prop "$n" ;;
      esac
    done ;;
  *) echo "usage: $0 [matrix|liveness|one STRATEGY PROPAGATION [K=V...] [-- PROPS...]]"; exit 1 ;;
esac
