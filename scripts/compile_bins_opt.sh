#!/usr/bin/env bash
set -Eeuo pipefail
PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$PROJ_DIR/src"
OUT="$PROJ_DIR/build_bins_opt"
INCLUDE_DIR="$PROJ_DIR/include"
mkdir -p "$OUT"
echo "Compilando (opt) en: $OUT"

# Flags agresivos de optimización (ajustar si lo deseas)
CFLAGS=(-O3 -march=native -flto -funroll-loops -fomit-frame-pointer -fno-common -std=c99 "-I$INCLUDE_DIR")
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
    echo " - $srcpath -> $outbin"
    mpicc "${CFLAGS[@]}" "$srcpath" "${COMMON_SOURCES[@]}" -o "$outbin" "${LDFLAGS[@]}" || {
      echo "Compilación falló para $srcpath"; exit 1;
    }
    chmod +x "$outbin"
  else
    echo " ! fuente no existe: $srcpath"
  fi
done

echo "Compilación opt completa."
