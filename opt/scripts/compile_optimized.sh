#!/usr/bin/env bash
# ============================================================================
# compile_optimized.sh - Compilar versiones optimizadas
# ============================================================================
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPT_DIR="$PROJ_DIR/opt"
BUILD_DIR="$OPT_DIR/build"
SRC_DIR="$OPT_DIR/src"
INCLUDE_DIR="$PROJ_DIR/include"
DES_UTILS="$PROJ_DIR/src/des_utils.c"

mkdir -p "$BUILD_DIR"

# Aggressive optimization flags
CFLAGS="-O3 -march=native -flto -ftree-vectorize -funroll-loops -fomit-frame-pointer -fno-common"
CFLAGS="$CFLAGS -DNDEBUG"
CFLAGS="$CFLAGS -Wall -Wextra -std=c11"
CFLAGS="$CFLAGS -I${INCLUDE_DIR}"

echo "============================================"
echo "  Compilando versiones optimizadas"
echo "============================================"
echo "Build dir: $BUILD_DIR"
echo "Flags:     $CFLAGS"
echo

# Check if des_utils.c exists
if [[ ! -f "$DES_UTILS" ]]; then
    echo "ERROR: No se encuentra $DES_UTILS"
    exit 1
fi

# Cyclic optimizado
if [[ -f "$SRC_DIR/bruteforce_mpi_cyclic_opt.c" ]]; then
    echo "▶ Compilando cyclic_opt..."
    mpicc $CFLAGS \
      "$SRC_DIR/bruteforce_mpi_cyclic_opt.c" \
      "$DES_UTILS" \
      -lcrypto -o "$BUILD_DIR/bruteforce_mpi_cyclic_opt"
    echo "  ✓ $BUILD_DIR/bruteforce_mpi_cyclic_opt"
else
    echo "  ⚠ Saltando cyclic_opt (archivo no encontrado)"
fi

# Adaptive optimizado
if [[ -f "$SRC_DIR/bruteforce_mpi_adaptive_opt.c" ]]; then
    echo "▶ Compilando adaptive_opt..."
    mpicc $CFLAGS \
      "$SRC_DIR/bruteforce_mpi_adaptive_opt.c" \
      "$DES_UTILS" \
      -lcrypto -o "$BUILD_DIR/bruteforce_mpi_adaptive_opt"
    echo "  ✓ $BUILD_DIR/bruteforce_mpi_adaptive_opt"
else
    echo "  ⚠ Saltando adaptive_opt (archivo no encontrado)"
fi

# Híbrido
if [[ -f "$SRC_DIR/bruteforce_mpi_hybrid.c" ]]; then
    echo "▶ Compilando hybrid..."
    mpicc $CFLAGS \
      "$SRC_DIR/bruteforce_mpi_hybrid.c" \
      "$DES_UTILS" \
      -lcrypto -o "$BUILD_DIR/bruteforce_mpi_hybrid"
    echo "  ✓ $BUILD_DIR/bruteforce_mpi_hybrid"
else
    echo "  ⚠ Saltando hybrid (archivo no encontrado)"
fi

echo
echo "============================================"
echo "  ✓ Compilación completada"
echo "============================================"
echo
echo "Binarios disponibles:"
ls -lh "$BUILD_DIR"/ 2>/dev/null | grep -v '^d' | awk '{print "  " $9 " (" $5 ")"}'
echo
echo "💡 Smoke test:"
echo "   mpirun -np 4 --bind-to core --map-by core \\"
echo "     $BUILD_DIR/bruteforce_mpi_cyclic_opt \\"
echo "     -c data/cipher.bin -s 'es una prueba de' \\"
echo "     -L 0 -U 2097152 -B 50000 --sync-freq 8"
echo
