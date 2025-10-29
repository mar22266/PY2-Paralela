#!/usr/bin/env bash
#
# check_pipeline_ready.sh — Verificar que el pipeline está listo para ejecutarse
#

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "========================================="
echo "  VERIFICACIÓN DE PIPELINE"
echo "========================================="
echo ""

ERRORS=0
WARNINGS=0

# ========================================
# 1. Verificar scripts
# ========================================
echo "1. Verificando scripts..."

SCRIPTS=(
    "scripts/round0_probe.sh"
    "scripts/round1a_algorithmic.sh"
    "scripts/round1b_tuning.sh"
    "scripts/round2_final.sh"
    "scripts/run_hybrid_pipeline.sh"
    "scripts/compile_bins_opt.sh"
    "scripts/bench_pipeline.py"
)

for script in "${SCRIPTS[@]}"; do
    if [[ -f "$script" ]]; then
        if [[ -x "$script" ]]; then
            echo "  ✓ $script (ejecutable)"
        else
            echo "  ⚠  $script (existe pero no es ejecutable)"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        echo "  ✗ $script (NO ENCONTRADO)"
        ERRORS=$((ERRORS + 1))
    fi
done

echo ""

# ========================================
# 2. Verificar binarios
# ========================================
echo "2. Verificando binarios compilados..."

if [[ ! -d "build_bins_opt" ]]; then
    echo "  ✗ build_bins_opt/ no existe"
    ERRORS=$((ERRORS + 1))
else
    BINARIES=(
        "build_bins_opt/bruteforce_seq"
        "build_bins_opt/bruteforce_mpi"
        "build_bins_opt/bruteforce_mpi_cyclic"
        "build_bins_opt/bruteforce_mpi_dynamic"
        "build_bins_opt/bruteforce_mpi_dynamic_adaptive"
        "build_bins_opt/bruteforce_mpi_permuted"
    )
    
    FOUND=0
    for bin in "${BINARIES[@]}"; do
        if [[ -f "$bin" ]]; then
            FOUND=$((FOUND + 1))
            echo "  ✓ $bin"
        else
            echo "  ✗ $bin (NO ENCONTRADO)"
        fi
    done
    
    if [[ $FOUND -lt 6 ]]; then
        echo ""
        echo "  ⚠  Solo $FOUND/6 binarios encontrados"
        echo "     Ejecuta: bash scripts/compile_bins_opt.sh"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

echo ""

# ========================================
# 3. Verificar datos
# ========================================
echo "3. Verificando archivos de datos..."

if [[ -f "data/cipher.bin" ]]; then
    echo "  ✓ data/cipher.bin"
else
    echo "  ✗ data/cipher.bin (NO ENCONTRADO)"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# ========================================
# 4. Verificar dependencias Python
# ========================================
echo "4. Verificando dependencias Python..."

if command -v python3 &> /dev/null; then
    echo "  ✓ python3 instalado"
    
    # Verificar pandas
    if python3 -c "import pandas" 2>/dev/null; then
        echo "  ✓ pandas instalado"
    else
        echo "  ⚠  pandas NO instalado (requerido para análisis)"
        echo "     Instala con: pip3 install pandas numpy"
        WARNINGS=$((WARNINGS + 1))
    fi
    
    # Verificar numpy
    if python3 -c "import numpy" 2>/dev/null; then
        echo "  ✓ numpy instalado"
    else
        echo "  ⚠  numpy NO instalado (requerido para análisis)"
        echo "     Instala con: pip3 install numpy"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo "  ✗ python3 NO instalado"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# ========================================
# 5. Verificar MPI
# ========================================
echo "5. Verificando MPI..."

if command -v mpirun &> /dev/null; then
    echo "  ✓ mpirun disponible"
    
    # Probar MPI básico
    if timeout 5 mpirun -np 2 echo "test" &>/dev/null; then
        echo "  ✓ MPI funciona correctamente"
    else
        echo "  ⚠  MPI disponible pero falla al ejecutar"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo "  ✗ mpirun NO disponible"
    ERRORS=$((ERRORS + 1))
fi

if command -v mpicc &> /dev/null; then
    echo "  ✓ mpicc disponible"
else
    echo "  ✗ mpicc NO disponible"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# ========================================
# 6. Verificar directorios
# ========================================
echo "6. Verificando estructura de directorios..."

DIRS=("artifacts" "logs" "data" "src" "scripts" "build_bins_opt")

for dir in "${DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        echo "  ✓ $dir/"
    else
        if [[ "$dir" == "artifacts" || "$dir" == "logs" ]]; then
            echo "  ⚠  $dir/ no existe (se creará automáticamente)"
            WARNINGS=$((WARNINGS + 1))
        else
            echo "  ✗ $dir/ NO existe"
            ERRORS=$((ERRORS + 1))
        fi
    fi
done

echo ""

# ========================================
# 7. Verificar herramientas auxiliares
# ========================================
echo "7. Verificando herramientas auxiliares..."

TOOLS=("bc" "grep" "sed" "awk" "timeout")

for tool in "${TOOLS[@]}"; do
    if command -v $tool &> /dev/null; then
        echo "  ✓ $tool"
    else
        echo "  ⚠  $tool NO disponible (puede causar problemas)"
        WARNINGS=$((WARNINGS + 1))
    fi
done

echo ""

# ========================================
# Resumen
# ========================================
echo "========================================="
echo "  RESUMEN"
echo "========================================="

if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
    echo "✅ TODO LISTO - El pipeline puede ejecutarse"
    echo ""
    echo "Comandos sugeridos:"
    echo "  # Pipeline completo"
    echo "  bash scripts/run_hybrid_pipeline.sh"
    echo ""
    echo "  # Solo exploración"
    echo "  bash scripts/run_hybrid_pipeline.sh --only-phase0"
    exit 0
elif [[ $ERRORS -eq 0 ]]; then
    echo "⚠️  HAY $WARNINGS ADVERTENCIA(S) - El pipeline debería funcionar"
    echo ""
    echo "Revisa las advertencias arriba. Puedes continuar con:"
    echo "  bash scripts/run_hybrid_pipeline.sh"
    exit 0
else
    echo "❌ HAY $ERRORS ERROR(ES) Y $WARNINGS ADVERTENCIA(S)"
    echo ""
    echo "Soluciones sugeridas:"
    
    if [[ ! -d "build_bins_opt" ]] || [[ $(ls -1 build_bins_opt/ 2>/dev/null | wc -l) -lt 6 ]]; then
        echo "  - Compilar binarios: bash scripts/compile_bins_opt.sh"
    fi
    
    if ! command -v python3 &> /dev/null || ! python3 -c "import pandas" 2>/dev/null; then
        echo "  - Instalar Python deps: pip3 install pandas numpy"
    fi
    
    if ! command -v mpirun &> /dev/null; then
        echo "  - Instalar MPI: sudo apt install openmpi-bin libopenmpi-dev"
    fi
    
    echo ""
    exit 1
fi
