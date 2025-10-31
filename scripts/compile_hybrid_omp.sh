#!/usr/bin/env bash
# Compilación de versión híbrida MPI+OpenMP
set -Eeuo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_HYBRID="$PROJ_DIR/src/hybrid"
SRC_COMMON="$PROJ_DIR/src"
OUT="$PROJ_DIR/build_bins_opt"
INCLUDE_DIR="$PROJ_DIR/include"

mkdir -p "$OUT"

echo "  Compilando versión híbrida MPI+OpenMP"

# Flags agresivos de optimización + OpenMP
CFLAGS=(
    -fopenmp                    # Habilitar OpenMP
    -O3 
    -march=native 
    -flto 
    -funroll-loops 
    -ftree-vectorize 
    -fomit-frame-pointer 
    -fno-common 
    -std=c11 
    "-I$INCLUDE_DIR"
)

LDFLAGS=(-fopenmp -flto -lcrypto)

# Manejar rutas de conda si está activo
if [[ -n "${CONDA_PREFIX:-}" && -d "$CONDA_PREFIX/lib" ]]; then
  LDFLAGS=("-L$CONDA_PREFIX/lib" "-Wl,-rpath,$CONDA_PREFIX/lib" "${LDFLAGS[@]}")
fi

# Archivos comunes (des_utils.c)
COMMON_SOURCES=()
if [[ -f "$SRC_COMMON/des_utils.c" ]]; then
  COMMON_SOURCES+=("$SRC_COMMON/des_utils.c")
fi

# Compilar versión híbrida
SRC_FILE="$SRC_HYBRID/bruteforce_mpi_cyclic_omp.c"
OUT_BIN="$OUT/bruteforce_mpi_cyclic_omp"

if [[ -f "$SRC_FILE" ]]; then
    echo "→ Compilando: $SRC_FILE"
    echo "  Output: $OUT_BIN"
    echo "  Flags: ${CFLAGS[*]}"
    
    if mpicc "${CFLAGS[@]}" "$SRC_FILE" "${COMMON_SOURCES[@]}" -o "$OUT_BIN" "${LDFLAGS[@]}"; then
        chmod +x "$OUT_BIN"
        echo "✔ Compilación exitosa"
        
        # Verificar soporte OpenMP
        echo ""
        echo "→ Verificando soporte OpenMP:"
        if strings "$OUT_BIN" | grep -q "GOMP"; then
            echo "✔ OpenMP detectado en binario (GOMP)"
        elif strings "$OUT_BIN" | grep -q "omp"; then
            echo "✔ OpenMP detectado en binario"
        else
            echo "⚠ Advertencia: OpenMP no detectado en binario"
        fi
    else
        echo "✘ Error en compilación"
        exit 1
    fi
else
    echo "✘ Error: archivo fuente no existe: $SRC_FILE"
    exit 1
fi

echo ""
echo "  Binario híbrido disponible en: $OUT_BIN"
echo ""
echo "Ejemplo de uso:"
echo "  export OMP_NUM_THREADS=2"
echo "  mpirun -np 4 $OUT_BIN \\"
echo "    -c data/cipher.bin \\"
echo "    -s \"es una prueba de\" \\"
echo "    -L 0 -U 8388608"
