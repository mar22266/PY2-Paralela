#!/usr/bin/env bash
# Ejecuta las 4 fases del benchmarking híbrido:

#
# Uso:
#   bash scripts/run_hybrid_pipeline.sh [opciones]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"


SKIP_PHASE0=0
SKIP_ROUND1A=0
ONLY_PHASE0=0
ONLY_ROUND1A=0
ONLY_ROUND1B=0
ONLY_ROUND2=0

# Parse arguments
for arg in "$@"; do
    case $arg in
        --skip-phase0) SKIP_PHASE0=1 ;;
        --skip-round1a) SKIP_ROUND1A=1 ;;
        --only-phase0) ONLY_PHASE0=1 ;;
        --only-round1a) ONLY_ROUND1A=1 ;;
        --only-round1b) ONLY_ROUND1B=1 ;;
        --only-round2) ONLY_ROUND2=1 ;;
    esac
done

export P="${P:-8}"
export REPS="${REPS:-3}"
export KEY="${KEY:-10000000}"
export MPIRUN_OVERSUBSCRIBE="${MPIRUN_OVERSUBSCRIBE:-1}"


echo "========================================"
echo "   PIPELINE HÍBRIDO DE BENCHMARKING"
echo "========================================"
echo "Configuración:"
echo "  P = $P"
echo "  REPS = $REPS"
echo "  KEY = $KEY"
echo "  MPIRUN_OVERSUBSCRIBE = $MPIRUN_OVERSUBSCRIBE"
echo ""


if [[ ! -d "build_bins_opt" ]] || [[ $(ls -1 build_bins_opt/*.* 2>/dev/null | wc -l) -lt 5 ]]; then
    echo "  Binarios no encontrados o incompletos en build_bins_opt/"
    echo "   Compilando con scripts/compile_bins_opt.sh..."
    bash scripts/compile_bins_opt.sh
    echo ""
fi


if [[ $ONLY_ROUND1A -eq 0 && $ONLY_ROUND1B -eq 0 && $ONLY_ROUND2 -eq 0 ]]; then
    if [[ $SKIP_PHASE0 -eq 0 ]]; then
        echo ""
        echo "========================================"
        echo "  FASE 0: Exploración de Hiperparámetros"
        echo "========================================"
        echo "Duración estimada: 5-10 minutos"
        echo ""
        
        if bash scripts/round0_probe.sh; then
            echo "✓ Fase 0 completada"
        else
            echo "✗ Fase 0 falló"
            exit 1
        fi
    else
        echo "⏭  Omitiendo Fase 0 (--skip-phase0)"
    fi
    
    if [[ $ONLY_PHASE0 -eq 1 ]]; then
        echo ""
        echo " Pipeline completado (solo Fase 0)"
        exit 0
    fi
fi

if [[ $ONLY_PHASE0 -eq 0 && $ONLY_ROUND1B -eq 0 && $ONLY_ROUND2 -eq 0 ]]; then
    if [[ $SKIP_ROUND1A -eq 0 ]]; then
        echo ""
        echo "========================================"
        echo "  ROUND 1A: Comparación Algorítmica"
        echo "========================================"
        echo "Duración estimada: 10-15 minutos"
        echo ""
        
        if bash scripts/round1a_algorithmic.sh; then
            echo "✓ Round 1A completado"
        else
            echo "✗ Round 1A falló"
            exit 1
        fi
    else
        echo "⏭️  Omitiendo Round 1A (--skip-round1a)"
    fi
    
    if [[ $ONLY_ROUND1A -eq 1 ]]; then
        echo ""
        echo "🏁 Pipeline completado (hasta Round 1A)"
        exit 0
    fi
fi


if [[ $ONLY_PHASE0 -eq 0 && $ONLY_ROUND1A -eq 0 && $ONLY_ROUND2 -eq 0 ]]; then
    echo ""
    echo "========================================"
    echo "  ROUND 1B: Optimización Individual"
    echo "========================================"
    echo "Duración estimada: 15-30 minutos (depende de sobrevivientes)"
    echo ""
    
    if bash scripts/round1b_tuning.sh; then
        echo "✓ Round 1B completado"
    else
        echo "✗ Round 1B falló"
        exit 1
    fi
    
    if [[ $ONLY_ROUND1B -eq 1 ]]; then
        echo ""
        echo "🏁 Pipeline completado (hasta Round 1B)"
        exit 0
    fi
fi


if [[ $ONLY_PHASE0 -eq 0 && $ONLY_ROUND1A -eq 0 && $ONLY_ROUND1B -eq 0 ]]; then
    echo ""
    echo "========================================"
    echo "  ROUND 2: Competencia Final"
    echo "========================================"
    echo "Duración estimada: 10-20 minutos"
    echo ""
    
    if bash scripts/round2_final.sh; then
        echo "✓ Round 2 completado"
    else
        echo "✗ Round 2 falló"
        exit 1
    fi
fi


echo ""
echo "========================================"
echo "   PIPELINE COMPLETADO"
echo "========================================"
echo ""
echo "Resultados:"

# Encontrar último round2
LAST_R2=$(ls -td artifacts/round2-* 2>/dev/null | head -1)
if [[ -n "$LAST_R2" ]]; then
    echo "   Reporte final: $LAST_R2/final_report.md"
    echo "   Ganadores: $LAST_R2/winners.json"
    echo "   CSV: $LAST_R2/csv/bench_round2.csv"
    
    if [[ -f "$LAST_R2/winners.json" ]]; then
        echo ""
        echo "Resumen de ganadores:"
        python3 -c "
import json
with open('$LAST_R2/winners.json') as f:
    winners = json.load(f)
for P, cats in winners.items():
    print(f'\nP={P}:')
    for cat, data in cats.items():
        print(f'  {cat:6s}: {data[\"variant\"]:15s} speedup={data[\"mean_speedup\"]:.3f}')
"
    fi
fi

echo ""
echo "Ver reporte completo en: $LAST_R2/final_report.md"
echo ""
