#!/usr/bin/env bash
set -Eeuo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJ_DIR/build_bins_opt"
SRC_DIR="$PROJ_DIR/src"
DATA="$PROJ_DIR/data"
LOGS="$PROJ_DIR/logs"

mkdir -p "$BUILD_DIR" "$DATA" "$LOGS"

TEXT="$DATA/mensaje.txt"
[[ -f "$TEXT" ]] || echo -n "Esta es una prueba de proyecto 2" > "$TEXT"

BINARIES=(
  "bruteforce_seq"
  "bruteforce_mpi_naive_opt"
  "bruteforce_mpi_cyclic_opt"
  "bruteforce_mpi_dynamic_opt"
  "bruteforce_mpi_dynamic_adaptive_opt"
  "bruteforce_mpi_permuted_opt"
)

echo "Checking binaries..."
for name in "${BINARIES[@]}"; do
  bin="$BUILD_DIR/$name"
  src="$SRC_DIR/${name}.c"
  
  if [[ ! -x "$bin" ]]; then
    if [[ -f "$src" ]]; then
      echo "Compiling $name..."
      if [[ "$name" == "bruteforce_seq" ]]; then
        gcc -O3 -o "$bin" "$src" -lcrypto -lm
      else
        mpicc -O3 -o "$bin" "$src" -lcrypto -lm
      fi
    else
      echo "Error: Source not found: $src"
      exit 1
    fi
  fi
done

BIN_SEQ="$BUILD_DIR/bruteforce_seq"
BIN_NAI="$BUILD_DIR/bruteforce_mpi_naive_opt"
BIN_CYC="$BUILD_DIR/bruteforce_mpi_cyclic_opt"
BIN_DYN="$BUILD_DIR/bruteforce_mpi_dynamic_opt"
BIN_ADA="$BUILD_DIR/bruteforce_mpi_dynamic_adaptive_opt"
BIN_PER="$BUILD_DIR/bruteforce_mpi_permuted_opt"

P="${P:-$(nproc)}"
RANGE_EASY="0 2097152"
RANGE_MED="0 4194304"
RANGE_HARD="0 8388608"
KEY=1048577
CIPHER="$DATA/cipher.bin"

run_variant() {
  local variant="$1"
  local category="$2"
  local bin="$3"
  local extra_args="$4"
  local range=()

  case "$category" in
    easy) range=($RANGE_EASY) ;;
    med)  range=($RANGE_MED) ;;
    hard) range=($RANGE_HARD) ;;
  esac

  local L=${range[0]}
  local U=${range[1]}
  local logfile="$LOGS/${variant}_${category}_round1.log"

  mpirun --oversubscribe -np "$P" "$bin" -c "$CIPHER" -s "prueba" -L "$L" -U "$U" $extra_args \
    > "$logfile" 2>&1
}

[[ -f "$CIPHER" ]] || "$BIN_SEQ" --encrypt -i "$TEXT" -k "$KEY" -o "$CIPHER"

for category in easy med hard; do
  run_variant "naive_opt" "$category" "$BIN_NAI" ""
  run_variant "cyclic_opt" "$category" "$BIN_CYC" ""
  
  for B in 20000 50000 100000; do
    run_variant "dynamic_opt_B${B}" "$category" "$BIN_DYN" "-B ${B}"
  done
  
  for T in 1.2 1.5 2.0; do
    run_variant "adaptive_opt_T${T}" "$category" "$BIN_ADA" "-T ${T}"
  done
  
  run_variant "permuted_opt" "$category" "$BIN_PER" ""
done

echo "mode_cache,bits,U,L,U_run,category,key,P,variant,chunk_B_or_T_or_R,t_seq_s,t_par_s,speedup,rank_found,tests_total,log_file" \
  > "$LOGS/bench_round1.csv"

grep -h "with_cache" "$LOGS"/*_round1.log >> "$LOGS/bench_round1.csv" || true