#!/usr/bin/env bash
# ============================================================================
# validate_reproducibility.sh - Verificar reproducibilidad del proyecto
# ============================================================================
# Objetivo: Validar que todos los scripts y binarios funcionan correctamente
# Uso: bash scripts/validate_reproducibility.sh

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "============================================"
echo "  Validación de Reproducibilidad"
echo "============================================"
echo ""

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

failures=0
checks=0

check_file() {
    local file="$1"
    local desc="$2"
    checks=$((checks + 1))
    if [[ -f "$file" ]]; then
        echo -e "${GREEN}✓${NC} $desc: $file"
    else
        echo -e "${RED}✗${NC} $desc: $file (MISSING)"
        failures=$((failures + 1))
    fi
}

check_dir() {
    local dir="$1"
    local desc="$2"
    checks=$((checks + 1))
    if [[ -d "$dir" ]]; then
        echo -e "${GREEN}✓${NC} $desc: $dir"
    else
        echo -e "${RED}✗${NC} $desc: $dir (MISSING)"
        failures=$((failures + 1))
    fi
}

check_executable() {
    local file="$1"
    local desc="$2"
    checks=$((checks + 1))
    if [[ -x "$file" ]]; then
        echo -e "${GREEN}✓${NC} $desc: $file"
    else
        echo -e "${RED}✗${NC} $desc: $file (NOT EXECUTABLE)"
        failures=$((failures + 1))
    fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1️⃣  Verificando Binarios Optimizados"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_executable "build_bins_opt/bruteforce_mpi" "Binario MPI naive"
check_executable "build_bins_opt/bruteforce_mpi_cyclic" "Binario MPI cyclic (GANADOR)"
check_executable "build_bins_opt/bruteforce_mpi_dynamic" "Binario MPI dynamic"
check_executable "build_bins_opt/bruteforce_mpi_dynamic_adaptive" "Binario MPI adaptive"
check_executable "build_bins_opt/bruteforce_mpi_permuted" "Binario MPI permuted"
check_executable "build_bins_opt/bruteforce_seq" "Binario secuencial"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2️⃣  Verificando Binarios Experimentales"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_executable "opt/build/bruteforce_mpi_cyclic_opt" "Cyclic chunked (experimental)"
check_executable "opt/build/bruteforce_mpi_adaptive_opt" "Adaptive batching (experimental)"
check_executable "opt/build/bruteforce_mpi_hybrid" "Hybrid SPMD (experimental)"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "3️⃣  Verificando Scripts del Pipeline"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_executable "scripts/compile_bins.sh" "Compilar binarios baseline"
check_executable "scripts/compile_bins_opt.sh" "Compilar binarios optimizados"
check_executable "scripts/round0_probe.sh" "Round 0: Exploración"
check_executable "scripts/round1a_algorithmic.sh" "Round 1A: Comparación"
check_executable "scripts/round1b_tuning.sh" "Round 1B: Tuning"
check_executable "scripts/round2_final.sh" "Round 2: Final"
check_executable "scripts/round3_scaling.sh" "Round 3: Scaling"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "4️⃣  Verificando Scripts de Profiling"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_executable "opt/scripts/profile_des_kernel.sh" "FASE A: Profiling DES"
check_executable "opt/scripts/vectorize_des_test.sh" "FASE B: Vectorización"
check_executable "opt/scripts/compile_optimized.sh" "Compilar opt/"
check_executable "scripts/benchmark_flags_long.sh" "Benchmark flags largo"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "5️⃣  Verificando Documentación"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_file "opt/INDEX.md" "Índice de documentación"
check_file "opt/README.md" "README optimizaciones"
check_file "opt/LESSONS_LEARNED.md" "Lecciones aprendidas"
check_file "opt/reports/FINAL_REPORT.md" "⭐ REPORTE FINAL"
check_file "opt/reports/PROFILING_SUMMARY.md" "Resumen profiling"
check_file "opt/reports/PROFILE_DES.md" "FASE A: Profile DES"
check_file "opt/reports/VECTORIZATION_DES.md" "FASE B: Vectorización"
check_file "opt/reports/COMPILER_FLAGS_FINAL.md" "Validación compiler flags"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "6️⃣  Verificando Artifacts de Resultados"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_dir "artifacts/round0-20251028_215602" "Round 0 artifacts"
check_dir "artifacts/round1a-20251028_220715" "Round 1A artifacts"
check_dir "artifacts/round1b-20251028_221003" "Round 1B artifacts"
check_dir "artifacts/round2-20251028_221420" "Round 2 artifacts"
check_dir "artifacts/scaling_round3_20251029_002408" "Round 3 artifacts"

check_file "artifacts/round0-20251028_215602/selected.json" "Round 0 results"
check_file "artifacts/round1a-20251028_220715/elimination_decisions.json" "Round 1A results"
check_file "artifacts/round1b-20251028_221003/best_configs.json" "Round 1B results"
check_file "artifacts/round2-20251028_221420/winners.json" "Round 2 results"
check_file "artifacts/scaling_round3_20251029_002408/scaling_report.md" "Round 3 report"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "7️⃣  Smoke Test: Ejecutar Binario Ganador"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ -x "build_bins_opt/bruteforce_mpi_cyclic" ]] && [[ -f "data/cipher.bin" ]]; then
    echo "Ejecutando smoke test (P=4, 2M keys)..."
    
    if timeout 10 mpirun -np 4 build_bins_opt/bruteforce_mpi_cyclic \
        -c data/cipher.bin -s "es una prueba de" \
        -L 0 -U 2097152 > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Smoke test PASSED"
    else
        echo -e "${RED}✗${NC} Smoke test FAILED"
        failures=$((failures + 1))
    fi
    checks=$((checks + 1))
else
    echo -e "${YELLOW}⚠${NC} Smoke test SKIPPED (binario o data missing)"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "8️⃣  Verificar Compilación con Flags Finales"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if grep -q "\-ftree\-vectorize" scripts/compile_bins_opt.sh; then
    echo -e "${GREEN}✓${NC} Compiler flags incluyen -ftree-vectorize"
else
    echo -e "${RED}✗${NC} Compiler flags NO incluyen -ftree-vectorize"
    failures=$((failures + 1))
fi

if grep -q "\-O3" scripts/compile_bins_opt.sh; then
    echo -e "${GREEN}✓${NC} Compiler flags incluyen -O3"
else
    echo -e "${RED}✗${NC} Compiler flags NO incluyen -O3"
    failures=$((failures + 1))
fi
checks=$((checks + 2))
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 RESUMEN"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total checks: $checks"
echo "Passed: $((checks - failures))"
echo "Failed: $failures"
echo ""

if [[ $failures -eq 0 ]]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ VALIDACIÓN EXITOSA${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "🎉 Proyecto PY2-Paralela está en estado limpio y reproducible"
    echo ""
    echo "📚 Próximos pasos:"
    echo "  1. Revisar: cat opt/reports/FINAL_REPORT.md"
    echo "  2. Reproducir profiling: bash opt/scripts/profile_des_kernel.sh"
    echo "  3. Reproducir benchmark: bash scripts/benchmark_flags_long.sh"
    echo ""
    exit 0
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}✗ VALIDACIÓN FALLÓ${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "⚠️  Por favor corrige los errores antes de continuar"
    echo ""
    echo "💡 Comandos sugeridos:"
    echo "  - Recompilar binarios: bash scripts/compile_bins_opt.sh"
    echo "  - Recompilar opt/: bash opt/scripts/compile_optimized.sh"
    echo ""
    exit 1
fi
