#!/usr/bin/env bash
set -Eeuo pipefail
PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$PROJ_DIR/src"
OUT="$PROJ_DIR/build_bins_opt"
INCLUDE_DIR="$PROJ_DIR/include"
mkdir -p "$OUT"

# Create artifacts/build_<timestamp> directory for logs
BUILD_TS="$(date +%Y%m%d_%H%M%S)"
ARTIFACTS_DIR="$PROJ_DIR/artifacts/build_${BUILD_TS}"
mkdir -p "$ARTIFACTS_DIR"
COMPILE_LOG="$ARTIFACTS_DIR/compile.log"

echo "Compilando (opt) en: $OUT" | tee "$COMPILE_LOG"
echo "Logs de compilación: $COMPILE_LOG" | tee -a "$COMPILE_LOG"

# Flags agresivos de optimización (basado en profiling FASE B)
# Ver: opt/reports/VECTORIZATION_DES.md - Mejora ~3% sobre -O2
CFLAGS=(-O3 -march=native -flto -funroll-loops -ftree-vectorize -fomit-frame-pointer -fno-common -std=c11 "-I$INCLUDE_DIR")
LDFLAGS=(-flto -lcrypto)

if [[ -n "${CONDA_PREFIX:-}" && -d "$CONDA_PREFIX/lib" ]]; then
  LDFLAGS=("-L$CONDA_PREFIX/lib" "-Wl,-rpath,$CONDA_PREFIX/lib" "${LDFLAGS[@]}")
fi

COMMON_SOURCES=()
if [[ -f "$SRC/des_utils.c" ]]; then
  COMMON_SOURCES+=("$SRC/des_utils.c")
fi

declare -A map
map[bruteforce_mpi]="bruteforce_mpi"
map[bruteforce_mpi_cyclic]="bruteforce_mpi_cyclic"
map[bruteforce_mpi_dynamic]="bruteforce_mpi_dynamic"
map[bruteforce_mpi_dynamic_adaptive]="bruteforce_mpi_dynamic_adaptive"
map[bruteforce_mpi_permuted]="bruteforce_mpi_permuted"
map[bruteforce_seq]="bruteforce_seq"

for src in "${!map[@]}"; do
  srcpath="$SRC/${src}.c"
  outbin="$OUT/${map[$src]}"
  if [[ -f "$srcpath" ]]; then
    echo " - $srcpath -> $outbin" | tee -a "$COMPILE_LOG"
    if mpicc "${CFLAGS[@]}" "$srcpath" "${COMMON_SOURCES[@]}" -o "$outbin" "${LDFLAGS[@]}" 2>&1 | tee -a "$COMPILE_LOG"; then
      chmod +x "$outbin"
    else
      echo "Compilación falló para $srcpath" | tee -a "$COMPILE_LOG"
      exit 1
    fi
  else
    echo " ! fuente no existe: $srcpath" | tee -a "$COMPILE_LOG"
  fi
done

echo "Compilación opt completa."
