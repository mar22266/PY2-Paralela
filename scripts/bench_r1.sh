#!/usr/bin/env bash
set -Eeuo pipefail
PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# -----------------------
# CONFIG / VARIABLES
# -----------------------
# Ajustes: cambia si hace falta
BUILD_DIR="${PROJ_DIR}/build_bins"          
ARTIFACTS_DIR="${PROJ_DIR}/artifacts"      
LOGS_ROOT="${PROJ_DIR}/logs"                
DATA_DIR="${PROJ_DIR}/data"
CIPHER="$DATA_DIR/cipher.bin"
TEXT="$DATA_DIR/mensaje.txt"
KEY="${KEY:-1048577}"

# parámetros de benchmarking
P_REQUESTED="${P:-8}"
BITS_LIST="${BITS_LIST:-"21 22 23"}"
RANGE_EASY="0 2097152"
RANGE_MED="0 4194304"
RANGE_HARD="0 8388608"

# -----------------------
# Preparación
# -----------------------
timestamp=$(date +%Y%m%d_%H%M%S)
RUN_DIR="$ARTIFACTS_DIR/round1-$timestamp"
RUN_LOG_DIR="$RUN_DIR/logs"
RUN_CSV_DIR="$RUN_DIR/csv"
mkdir -p "$RUN_LOG_DIR" "$RUN_CSV_DIR" "$BUILD_DIR" "$LOGS_ROOT"

echo "▶ Run isolated: $RUN_DIR"

# -----------------------
# Detectar cores y mpirun options
# -----------------------
if command -v nproc >/dev/null 2>&1; then
  CORES=$(nproc)
else
  CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
fi

if [[ "$P_REQUESTED" -gt "$CORES" ]]; then
  echo "⚠ P solicitado ($P_REQUESTED) > cores($CORES). Ajustando P=$CORES"
  P=$CORES
else
  P=$P_REQUESTED
fi

MPIRUN_EXTRA=""
if [[ "${MPIRUN_OVERSUBSCRIBE:-0}" == "1" ]]; then
  MPIRUN_EXTRA="--oversubscribe"
fi

echo " - Procesos (P) = $P"
echo " - MPIRUN_EXTRA = '$MPIRUN_EXTRA'"

# -----------------------
# Compilar si no hay binarios en BUILD_DIR
# -----------------------
if [[ ! -x "$BUILD_DIR/bruteforce_mpi" ]]; then
  echo " Binarios no encontrados en $BUILD_DIR — compilando..."
  bash "$PROJ_DIR/scripts/compile_bins.sh"
fi

# check binarios requeridos
for b in bruteforce_seq bruteforce_mpi bruteforce_mpi_cyclic bruteforce_mpi_dynamic bruteforce_mpi_dynamic_adaptive bruteforce_mpi_permuted; do
  if [[ ! -x "$BUILD_DIR/$b" ]]; then
    echo "ERROR: falta binario: $BUILD_DIR/$b"
    exit 1
  fi
done

# -----------------------
# Generar cipher si no existe
# -----------------------
if [[ ! -f "$CIPHER" ]]; then
  echo " Generando cipher base..."
  "$BUILD_DIR/bruteforce_seq" --encrypt -i "$TEXT" -k "$KEY" -o "$CIPHER"
fi

# -----------------------
# Función para ejecutar y guardar logs en RUN_LOG_DIR
# -----------------------
run_variant() {
  local variant_bin="$1"   # ruta absoluta
  local variant_tag="$2"   # nombre identificador (ej: naive_opt)
  local category="$3"      # easy|med|hard
  local extra_args="$4"    # argumentos adicionales (-B / -T)

  case "$category" in
    easy) range=($RANGE_EASY) ;;
    med)  range=($RANGE_MED) ;;
    hard) range=($RANGE_HARD) ;;
    *) echo "Unknown category $category"; exit 1 ;;
  esac

  L=${range[0]}; U=${range[1]}
  logfile="$RUN_LOG_DIR/${variant_tag}_${category}_round1.log"
  echo "▶ Ejecutando $variant_tag ($category) -> $logfile"
  mpirun $MPIRUN_EXTRA -np "$P" "$variant_bin" -c "$CIPHER" -s "prueba" -L "$L" -U "$U" $extra_args > "$logfile" 2>&1 || true
  echo "  -> guardado: $logfile"
}

# -----------------------
# Ejecutar variantes (no crear miles de archivos; logs aislados en RUN_LOG_DIR)
# -----------------------
echo "=== Ejecutando Round1 variants (logs en $RUN_LOG_DIR) ==="

# Naive (usamos bruteforce_mpi como representante)
run_variant "$BUILD_DIR/bruteforce_mpi" "naive_opt" "easy" ""
run_variant "$BUILD_DIR/bruteforce_mpi" "naive_opt" "med" ""
run_variant "$BUILD_DIR/bruteforce_mpi" "naive_opt" "hard" ""

# Cyclic
run_variant "$BUILD_DIR/bruteforce_mpi_cyclic" "cyclic_opt" "easy" ""
run_variant "$BUILD_DIR/bruteforce_mpi_cyclic" "cyclic_opt" "med" ""
run_variant "$BUILD_DIR/bruteforce_mpi_cyclic" "cyclic_opt" "hard" ""

# Dynamic (barrido B)
for B in 20000 50000 100000; do
  run_variant "$BUILD_DIR/bruteforce_mpi_dynamic" "dynamic_opt_B${B}" "easy" "-B ${B}"
  run_variant "$BUILD_DIR/bruteforce_mpi_dynamic" "dynamic_opt_B${B}" "med"  "-B ${B}"
  run_variant "$BUILD_DIR/bruteforce_mpi_dynamic" "dynamic_opt_B${B}" "hard" "-B ${B}"
done

# Adaptive (barrido T)
for T in 1.2 1.5 2.0; do
  run_variant "$BUILD_DIR/bruteforce_mpi_dynamic_adaptive" "adaptive_opt_T${T}" "easy" "-T ${T}"
  run_variant "$BUILD_DIR/bruteforce_mpi_dynamic_adaptive" "adaptive_opt_T${T}" "med"  "-T ${T}"
  run_variant "$BUILD_DIR/bruteforce_mpi_dynamic_adaptive" "adaptive_opt_T${T}" "hard" "-T ${T}"
done

# Permuted
run_variant "$BUILD_DIR/bruteforce_mpi_permuted" "permuted_opt" "easy" ""
run_variant "$BUILD_DIR/bruteforce_mpi_permuted" "permuted_opt" "med"  ""
run_variant "$BUILD_DIR/bruteforce_mpi_permuted" "permuted_opt" "hard" ""

# -----------------------
# Consolidar bench_round1.csv en RUN_CSV_DIR  (un solo CSV)
# -----------------------
OUT_CSV="$RUN_CSV_DIR/bench_round1.csv"
echo "mode_cache,bits,U,L,U_run,category,key,P,variant,chunk_B_or_T_or_R,t_seq_s,t_par_s,speedup,rank_found,tests_total,log_file" > "$OUT_CSV"
T_SEQ=3.056193

# extrae datos de cada log producido
for f in "$RUN_LOG_DIR"/*_round1.log; do
  bn=$(basename "$f" .log)
  category=$(echo "$bn" | sed -n 's/.*_\([a-z]*\)_round1$/\1/p')
  variant=$(echo "$bn" | sed -E "s/_${category}_round1\$//")
  P_ex=$(grep -m1 -E 'Procesos *:' "$f" | sed -E 's/.*: *([0-9]+).*/\1/' || echo "$P")
  t_par_s=$(grep -E 'Tiempo total .*max rank' "$f" | sed -E 's/.*: *([0-9]+\.[0-9]+) .*/\1/' || true)
  if [[ -z "$t_par_s" ]]; then
    t_par_s=$(grep -E 'Tiempo total' "$f" | sed -E 's/.*: *([0-9]+\.[0-9]+).*/\1/' || true)
  fi
  t_par_s=${t_par_s:-NaN}
  rank_found=$(grep -m1 -E '^- Rank *:|Rank *:' "$f" | sed -E 's/.*: *([0-9]+).*/\1/' || echo "")
  tests_total=$(awk -F'|' '/\|/ && $2 ~ /[0-9]/ { gsub(/ /,"",$2); s += $2 } END { if (s==0) print ""; else print s }' "$f")
  # chunk
  chunk=""
  if echo "$variant" | grep -q 'B[0-9]\+'; then
    chunk=$(echo "$variant" | sed -n 's/.*B\([0-9]\+\).*/\1/p')
  elif echo "$variant" | grep -q 'T[0-9]\+'; then
    chunk=$(echo "$variant" | sed -n 's/.*T\([0-9\.]\+\).*/\1/p')
  fi
  speedup="NaN"
  if echo "$t_par_s" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
    speedup=$(awk -v ts="$T_SEQ" -v tp="$t_par_s" 'BEGIN{ if(tp>0) printf("%.6f", ts/tp); else print "NaN" }')
  fi
  echo "with_cache, , , , ,${category},${KEY},${P_ex},${variant},${chunk},${T_SEQ},${t_par_s},${speedup},${rank_found},${tests_total},${f}" >> "$OUT_CSV"
done

# copy only CSV to project's logs/ so logs/ keeps solo CSVs (no logs)
cp -f "$OUT_CSV" "$LOGS_ROOT/bench_round1-${timestamp}.csv"

echo " Round1 aislado finalizado."
echo " - Artifacts: $RUN_DIR"
echo " - CSV consolidado: $OUT_CSV"
echo " - Copiado a: $LOGS_ROOT/bench_round1-${timestamp}.csv"
