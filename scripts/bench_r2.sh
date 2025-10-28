#!/usr/bin/env bash
set -Eeuo pipefail
PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PROJ_DIR}/build_bins_opt"
ARTIFACTS="${PROJ_DIR}/artifacts"
OUT_ROOT="$ARTIFACTS"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_DIR="$OUT_ROOT/round2-$TIMESTAMP"
LOG_DIR="$RUN_DIR/logs"
CSV_DIR="$RUN_DIR/csv"
mkdir -p "$LOG_DIR" "$CSV_DIR"

# CONFIG
P_LIST="${P_LIST:-8}"            # ejemplo: "2 4 8 16" o sólo 8
REPS="${REPS:-3}"               # réplicas por combinación
VARIANTS=( "bruteforce_mpi_cyclic" "bruteforce_mpi_dynamic" "bruteforce_mpi_dynamic_adaptive" )
# parámetros de ejecución (hard)
L="${L:-0}"
U="${U:-8388608}"               # hard range; ajustar si tu baseline usa otro
CIPHER="${CIPHER:-$PROJ_DIR/data/cipher.bin}"  # asegúrate de que sea el mismo cipher que el baseline
SUBSTR="${SUBSTR:-prueba}"

echo "Round2 isolated -> $RUN_DIR"
echo "Variants: ${VARIANTS[*]}"
echo "P list: $P_LIST, reps: $REPS, range: [$L,$U)"

# Check bins
for v in "${VARIANTS[@]}"; do
  if [[ ! -x "$BUILD_DIR/$v" ]]; then
    echo "ERROR: binario no encontrado: $BUILD_DIR/$v"
    echo "Ejecuta: scripts/compile_bins_opt.sh"
    exit 1
  fi
done

# Run loop
for P in $P_LIST; do
  for v in "${VARIANTS[@]}"; do
    tag=$(basename "$v")
    for rep in $(seq 1 $REPS); do
      logf="$LOG_DIR/${tag}_hard_p${P}_rep${rep}.log"
      echo "Run: $tag P=$P rep=$rep -> $logf"
      mpirun -np "$P" --oversubscribe "$BUILD_DIR/$v" -c "$CIPHER" -s "$SUBSTR" -L "$L" -U "$U" > "$logf" 2>&1 || true
      sleep 0.5
    done
  done
done

# Consolidar CSV (one-liner similar al pipeline extractor)
OUT_CSV="$CSV_DIR/bench_round2.csv"
echo "mode_cache,bits,U,L,U_run,category,key,P,variant,chunk_B_or_T_or_R,t_seq_s,t_par_s,speedup,rank_found,tests_total,log_file" > "$OUT_CSV"
TSEQ="${TSEQ:-3.056193}"

for f in "$LOG_DIR"/*.log; do
  bn=$(basename "$f" .log)
  # infer variant tag and P and rep
  variant_tag=$(echo "$bn" | sed -E 's/_hard_.*//')
  P_ex=$(echo "$bn" | sed -E -n 's/.*_p([0-9]+)_.*/\1/p')
  if [[ -z "$P_ex" ]]; then
    P_ex="$P"
  fi
  # try to parse t_par from log
  t_par_s=$(grep -E 'Tiempo total .*max rank' "$f" | sed -E 's/.*: *([0-9]+\.[0-9]+).*/\1/' || true)
  if [[ -z "$t_par_s" ]]; then
    t_par_s=$(grep -E 'Tiempo total' "$f" | sed -E 's/.*: *([0-9]+\.[0-9]+).*/\1/' || true)
  fi
  rank_found=$(grep -m1 -E '^- Rank *:|Rank *:' "$f" | sed -E 's/.*: *([0-9]+).*/\1/' || echo "")
  tests_total=$(awk -F'|' '/\|/ && $2 ~ /[0-9]/ { gsub(/ /,"",$2); s += $2 } END { if (s==0) print ""; else print s }' "$f")
  speedup="NaN"
  if echo "$t_par_s" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
    speedup=$(awk -v ts="$TSEQ" -v tp="$t_par_s" 'BEGIN{ if(tp>0) printf("%.6f", ts/tp); else print "NaN" }')
  fi
  echo "with_cache,${BITS:-},${U},${L},${U},hard,1048577,${P_ex},${variant_tag},,${TSEQ},${t_par_s},${speedup},${rank_found},${tests_total},${f}" >> "$OUT_CSV"
done

cp -f "$OUT_CSV" "$PROJ_DIR/logs/bench_round2-$(date +%Y%m%d_%H%M%S).csv"
echo "Round2 finished. CSV: $OUT_CSV  -> copied to logs/"

