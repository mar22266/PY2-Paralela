#!/usr/bin/env bash
#
# round1a_algorithmic.sh — ROUND 1A: Comparación Algorítmica
#
# Meta: Medir "mérito intrínseco" del enfoque bajo igualdad de condiciones.
# Todos compilan con -O3 -march=native -DNDEBUG sin trucos específicos.
# Parámetros obligatorios usan valores medianos del grid de Fase 0.
#

set -euo pipefail

# ========================================
# Configuración
# ========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

BUILD_DIR="${BUILD_DIR:-build_bins_opt}"
CIPHER="${CIPHER:-data/cipher.bin}"
SUBSTR="${SUBSTR:-prueba}"
KEY="${KEY:-10000000}"
P="${P:-8}"
MPIRUN_OVERSUBSCRIBE="${MPIRUN_OVERSUBSCRIBE:-1}"
REPS="${REPS:-3}"  # Réplicas por categoría

# Timestamp
TS="$(date +%Y%m%d_%H%M%S)"
ARTIFACTS_DIR="artifacts/round1a-$TS"
LOGS_DIR="$ARTIFACTS_DIR/logs"
CSV_DIR="$ARTIFACTS_DIR/csv"

mkdir -p "$LOGS_DIR" "$CSV_DIR"

# Rangos
declare -A RANGES
RANGES[easy]="0 2097152"   # 2^21
RANGES[med]="0 4194304"    # 2^22
RANGES[hard]="0 8388608"   # 2^23

# Parámetros medianos (según grid de Fase 0)
DYNAMIC_B_MEDIAN=50000
ADAPTIVE_T_MEDIAN=1.5
PERMUTED_R_MEDIAN=12345

# ========================================
# Verificar binarios
# ========================================
echo "========================================="
echo "ROUND 1A: Comparación Algorítmica"
echo "========================================="
echo "Condiciones: -O3 -march=native (igualdad)"
echo "P=$P, KEY=$KEY, REPS=$REPS"
echo "Artifacts: $ARTIFACTS_DIR"
echo ""

if [[ ! -d "$BUILD_DIR" ]]; then
    echo "ERROR: $BUILD_DIR no existe. Ejecuta scripts/compile_bins_opt.sh"
    exit 1
fi

# ========================================
# CSV Header
# ========================================
CSV_FILE="$CSV_DIR/bench_round1a.csv"
echo "category,variant,rep,param_used,P,t_seq_s,t_par_s,speedup,efficiency,rank_found,tests_total,log_file" > "$CSV_FILE"

# ========================================
# Helper: ejecutar variante
# ========================================
run_variant() {
    local variant=$1
    local category=$2
    local rep=$3
    local extra_args=$4
    
    read -r L U <<< "${RANGES[$category]}"
    
    local bin_name="bruteforce_mpi"
    case $variant in
        cyclic) bin_name="bruteforce_mpi_cyclic" ;;
        dynamic) bin_name="bruteforce_mpi_dynamic" ;;
        adaptive) bin_name="bruteforce_mpi_dynamic_adaptive" ;;
        permuted) bin_name="bruteforce_mpi_permuted" ;;
        naive) bin_name="bruteforce_mpi" ;;
    esac
    
    local bin="$BUILD_DIR/$bin_name"
    if [[ ! -f "$bin" ]]; then
        echo "  SKIP: $bin not found"
        return 1
    fi
    
    local log_file="$LOGS_DIR/${variant}_${category}_rep${rep}.log"
    local cmd_args="-c $CIPHER -s $SUBSTR -L $L -U $U -k $KEY $extra_args"
    
    local mpirun_extra=""
    [[ $MPIRUN_OVERSUBSCRIBE -eq 1 ]] && mpirun_extra="--oversubscribe"
    
    echo "  [$rep/$REPS] $variant $category"
    
    if timeout 180 mpirun -np "$P" $mpirun_extra "$bin" $cmd_args > "$log_file" 2>&1; then
        # Parsear
        local t_par=$(grep -oP 'Tiempo total.*:\s*\K[0-9.]+' "$log_file" | head -1)
        local rank_found=$(grep -oP 'rank_found:\s*\K-?\d+' "$log_file" | head -1)
        local tests_total=$(grep -oP 'tests_total:\s*\K\d+' "$log_file" | head -1)
        
        # t_seq
        local tseq_cache="$LOGS_DIR/.tseq_${category}_${L}_${U}"
        local t_seq
        if [[ -f "$tseq_cache" ]]; then
            t_seq=$(cat "$tseq_cache")
        else
            if [[ -f "$BUILD_DIR/bruteforce_seq" ]]; then
                local seq_log="$LOGS_DIR/seq_${category}.log"
                timeout 180 "$BUILD_DIR/bruteforce_seq" --bruteforce -c "$CIPHER" -s "$SUBSTR" \
                    -L "$L" -U "$U" > "$seq_log" 2>&1 || true
                t_seq=$(grep -oP 'Tiempo total.*:\s*\K[0-9.]+' "$seq_log" | head -1)
                [[ -n "$t_seq" ]] && echo "$t_seq" > "$tseq_cache"
            else
                t_seq="0"
            fi
        fi
        
        local speedup="0"
        local efficiency="0"
        if [[ -n "$t_seq" && -n "$t_par" ]] && (( $(echo "$t_par > 0" | bc -l 2>/dev/null || echo 0) )); then
            speedup=$(echo "scale=6; $t_seq / $t_par" | bc -l)
            efficiency=$(echo "scale=6; $speedup / $P" | bc -l)
        fi
        
        echo "$category,$variant,$rep,$extra_args,$P,$t_seq,$t_par,$speedup,$efficiency,$rank_found,$tests_total,$log_file" >> "$CSV_FILE"
    else
        echo "  TIMEOUT/FAILED"
        return 1
    fi
}

# ========================================
# Ejecución: Todas las variantes
# ========================================

VARIANTS="naive cyclic dynamic adaptive permuted"
CATEGORIES="easy med hard"

for variant in $VARIANTS; do
    echo ""
    echo "=== Variante: $variant ==="
    
    # Determinar parámetros
    case $variant in
        dynamic)
            extra_args="-B $DYNAMIC_B_MEDIAN"
            ;;
        adaptive)
            extra_args="-T $ADAPTIVE_T_MEDIAN"
            ;;
        permuted)
            extra_args="-R $PERMUTED_R_MEDIAN"
            ;;
        *)
            extra_args=""
            ;;
    esac
    
    for category in $CATEGORIES; do
        for rep in $(seq 1 $REPS); do
            run_variant "$variant" "$category" "$rep" "$extra_args" || true
        done
    done
done

# ========================================
# Copiar CSV a logs/
# ========================================
cp "$CSV_FILE" "logs/bench_round1a-$TS.csv"

# ========================================
# Análisis: Calcular métricas y decidir eliminación
# ========================================
echo ""
echo "========================================="
echo "Analizando resultados (eliminación fundamental)..."
echo "========================================="

python3 - "$CSV_FILE" "$ARTIFACTS_DIR" <<'PYTHON_SCRIPT'
import pandas as pd
import numpy as np
import json
import sys
from pathlib import Path

csv_path = Path(sys.argv[1])
artifacts_dir = sys.argv[2]

df = pd.read_csv(csv_path)

# Coerce numeric
for col in ['t_seq_s', 't_par_s', 'speedup', 'efficiency']:
    df[col] = pd.to_numeric(df[col], errors='coerce')

# Filtrar válidos
df = df[(df['speedup'] > 0) & (df['t_par_s'] > 0)].copy()

# Agregar por variante y categoría
summary = df.groupby(['variant', 'category']).agg(
    reps=('speedup', 'count'),
    mean_speedup=('speedup', 'mean'),
    std_speedup=('speedup', 'std'),
    mean_eff=('efficiency', 'mean'),
    std_eff=('efficiency', 'std'),
).reset_index()

print("\n=== Resumen por Variante y Categoría ===")
print(summary.to_string(index=False))

# Criterios de eliminación
decisions = {}
for variant in summary['variant'].unique():
    vdf = summary[summary['variant'] == variant]
    
    # Contar categorías con mean_eff < 0.10
    low_eff_cats = len(vdf[vdf['mean_eff'] < 0.10])
    
    # Contar categorías con mean_speedup < 1.0
    slower_than_seq = len(vdf[vdf['mean_speedup'] < 1.0])
    
    # Decisión
    if low_eff_cats >= 2:
        decision = "ELIMINAR"
        reason = f"Eficiencia < 10% en {low_eff_cats} categorías"
    elif slower_than_seq > 0:
        decision = "ELIMINAR"
        reason = f"Speedup < 1.0 en {slower_than_seq} categoría(s)"
    else:
        decision = "SOBREVIVE"
        reason = "Cumple criterios mínimos"
    
    decisions[variant] = {
        'decision': decision,
        'reason': reason,
        'mean_speedup_overall': float(vdf['mean_speedup'].mean()),
        'mean_eff_overall': float(vdf['mean_eff'].mean()),
        'categories_low_eff': int(low_eff_cats),
        'categories_slower_seq': int(slower_than_seq)
    }

# Guardar decisiones
output_dir = Path(artifacts_dir)
decision_file = output_dir / "elimination_decisions.json"
with open(decision_file, 'w') as f:
    json.dump(decisions, f, indent=2)

print("\n=== Decisiones de Eliminación ===")
for variant, data in decisions.items():
    status_emoji = "✓" if data['decision'] == "SOBREVIVE" else "✗"
    print(f"{status_emoji} {variant:20s} {data['decision']:10s} - {data['reason']}")
    print(f"   Mean speedup: {data['mean_speedup_overall']:.3f}, Mean eff: {data['mean_eff_overall']:.3f}")

survivors = [v for v, d in decisions.items() if d['decision'] == "SOBREVIVE"]
print(f"\n✓ SOBREVIVIENTES: {', '.join(survivors)}")
print(f"\nDecisiones guardadas en: {decision_file}")

PYTHON_SCRIPT

echo ""
echo "========================================="
echo "ROUND 1A Completado"
echo "========================================="
echo "CSV: $CSV_FILE"
echo "Decisiones: $ARTIFACTS_DIR/elimination_decisions.json"
echo ""
echo "Siguiente paso: bash scripts/round1b_tuning.sh"
