#!/usr/bin/env bash
#
# round1b_tuning.sh — ROUND 1B: Optimización Individual
#
# Meta: Encontrar la mejor versión de cada sobreviviente de Round 1A.
# Cada variante se optimiza según sus fortalezas específicas.
#
# Entrada: $SURVIVORS (o lee de round1a elimination_decisions.json)
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
REPS="${REPS:-3}"

# Timestamp
TS="$(date +%Y%m%d_%H%M%S)"
ARTIFACTS_DIR="artifacts/round1b-$TS"
LOGS_DIR="$ARTIFACTS_DIR/logs"
CSV_DIR="$ARTIFACTS_DIR/csv"

mkdir -p "$LOGS_DIR" "$CSV_DIR"

# Rangos
declare -A RANGES
RANGES[easy]="0 2097152"
RANGES[med]="0 4194304"
RANGES[hard]="0 8388608"

# ========================================
# Determinar sobrevivientes
# ========================================
SURVIVORS="${SURVIVORS:-}"

if [[ -z "$SURVIVORS" ]]; then
    # Buscar el último round1a
    LAST_R1A=$(ls -td artifacts/round1a-* 2>/dev/null | head -1)
    if [[ -n "$LAST_R1A" && -f "$LAST_R1A/elimination_decisions.json" ]]; then
        echo "Leyendo sobrevivientes de: $LAST_R1A/elimination_decisions.json"
        SURVIVORS=$(python3 -c "
import json
with open('$LAST_R1A/elimination_decisions.json') as f:
    data = json.load(f)
survivors = [v for v, d in data.items() if d['decision'] == 'SOBREVIVE']
print(' '.join(survivors))
")
    else
        echo "ADVERTENCIA: No se encontró round1a. Usando sobrevivientes por defecto."
        SURVIVORS="cyclic adaptive"
    fi
fi

echo "========================================="
echo "ROUND 1B: Optimización Individual"
echo "========================================="
echo "Sobrevivientes: $SURVIVORS"
echo "P=$P, KEY=$KEY, REPS=$REPS"
echo "Artifacts: $ARTIFACTS_DIR"
echo ""

# ========================================
# CSV Header
# ========================================
CSV_FILE="$CSV_DIR/bench_round1b.csv"
echo "category,variant,config_id,param_spec,rep,P,t_seq_s,t_par_s,speedup,efficiency,rank_found,tests_total,log_file" > "$CSV_FILE"

# ========================================
# Helper: ejecutar configuración
# ========================================
run_config() {
    local variant=$1
    local category=$2
    local config_id=$3
    local param_spec=$4
    local rep=$5
    
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
    
    local log_file="$LOGS_DIR/${variant}_${config_id}_${category}_rep${rep}.log"
    local cmd_args="-c $CIPHER -s $SUBSTR -L $L -U $U -k $KEY $param_spec"
    
    local mpirun_extra=""
    [[ $MPIRUN_OVERSUBSCRIBE -eq 1 ]] && mpirun_extra="--oversubscribe"
    
    echo "  [$rep/$REPS] $variant $category config=$config_id"
    
    if timeout 180 mpirun -np "$P" $mpirun_extra "$bin" $cmd_args > "$log_file" 2>&1; then
        local t_par=$(grep -oP 'Tiempo total.*:\s*\K[0-9.]+' "$log_file" | head -1)
        local rank_found=$(grep -oP 'rank_found:\s*\K-?\d+' "$log_file" | head -1)
        local tests_total=$(grep -oP 'tests_total:\s*\K\d+' "$log_file" | head -1)
        
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
        
        echo "$category,$variant,$config_id,$param_spec,$rep,$P,$t_seq,$t_par,$speedup,$efficiency,$rank_found,$tests_total,$log_file" >> "$CSV_FILE"
    else
        echo "  TIMEOUT/FAILED"
        return 1
    fi
}

# ========================================
# Tuning: CYCLIC
# ========================================
if [[ " $SURVIVORS " =~ " cyclic " ]]; then
    echo ""
    echo "=== Tuning CYCLIC ==="
    echo "  (Sin hiperparámetros, solo confirmación de rendimiento base)"
    
    for category in easy med hard; do
        for rep in $(seq 1 $REPS); do
            run_config "cyclic" "$category" "base" "" "$rep" || true
        done
    done
fi

# ========================================
# Tuning: ADAPTIVE
# ========================================
if [[ " $SURVIVORS " =~ " adaptive " ]]; then
    echo ""
    echo "=== Tuning ADAPTIVE (barrido denso de T) ==="
    
    # Barrido denso: T ∈ [1.0, 2.5] paso 0.2
    T_VALUES=(1.0 1.2 1.4 1.5 1.6 1.8 2.0 2.2 2.5)
    
    for T in "${T_VALUES[@]}"; do
        echo "  Config: T=$T"
        for category in easy med hard; do
            for rep in $(seq 1 $REPS); do
                run_config "adaptive" "$category" "T${T}" "-T $T" "$rep" || true
            done
        done
    done
fi

# ========================================
# Tuning: DYNAMIC (repechaje diagnóstico, opcional)
# ========================================
if [[ " $SURVIVORS " =~ " dynamic " ]]; then
    echo ""
    echo "=== Tuning DYNAMIC (repechaje - grid fino de B) ==="
    
    B_VALUES=(10000 20000 30000 50000 100000)
    
    for B in "${B_VALUES[@]}"; do
        echo "  Config: B=$B"
        for category in easy med hard; do
            for rep in $(seq 1 $REPS); do
                run_config "dynamic" "$category" "B${B}" "-B $B" "$rep" || true
            done
        done
    done
fi

# ========================================
# Tuning: PERMUTED (repechaje diagnóstico, opcional)
# ========================================
if [[ " $SURVIVORS " =~ " permuted " ]]; then
    echo ""
    echo "=== Tuning PERMUTED (repechaje - seeds) ==="
    
    R_VALUES=(12345 54321 98765 11111)
    
    for R in "${R_VALUES[@]}"; do
        echo "  Config: R=$R"
        for category in easy med hard; do
            for rep in $(seq 1 $REPS); do
                run_config "permuted" "$category" "R${R}" "-R $R" "$rep" || true
            done
        done
    done
fi

# ========================================
# Copiar CSV a logs/
# ========================================
cp "$CSV_FILE" "logs/bench_round1b-$TS.csv"

# ========================================
# Análisis: Seleccionar mejores configs y aplicar criterio de pase a Round 2
# ========================================
echo ""
echo "========================================="
echo "Analizando resultados y seleccionando mejores configs..."
echo "========================================="

python3 - "$CSV_FILE" "$ARTIFACTS_DIR" "$LAST_R1A" <<'PYTHON_SCRIPT'
import pandas as pd
import numpy as np
import json
import sys
from pathlib import Path

csv_path = Path(sys.argv[1])
artifacts_dir = sys.argv[2]
last_r1a = sys.argv[3]

df = pd.read_csv(csv_path)

# Coerce numeric
for col in ['t_seq_s', 't_par_s', 'speedup', 'efficiency']:
    df[col] = pd.to_numeric(df[col], errors='coerce')

df = df[(df['speedup'] > 0) & (df['t_par_s'] > 0)].copy()

# Agregar por variante, config, categoría
summary = df.groupby(['variant', 'config_id', 'category']).agg(
    reps=('speedup', 'count'),
    mean_speedup=('speedup', 'mean'),
    std_speedup=('speedup', 'std'),
    mean_eff=('efficiency', 'mean'),
    param_spec=('param_spec', 'first'),
).reset_index()

print("\n=== Resumen por Config ===")
print(summary.to_string(index=False))

# Seleccionar mejor config por variante y categoría
best_configs = {}

for variant in summary['variant'].unique():
    best_configs[variant] = {}
    vdf = summary[summary['variant'] == variant]
    
    for category in vdf['category'].unique():
        cdf = vdf[vdf['category'] == category]
        
        # Mejor: máximo mean_speedup
        best_idx = cdf['mean_speedup'].idxmax()
        best_row = cdf.loc[best_idx]
        
        best_configs[variant][category] = {
            'config_id': str(best_row['config_id']),
            'param_spec': str(best_row['param_spec']),
            'mean_speedup': float(best_row['mean_speedup']),
            'std_speedup': float(best_row['std_speedup']) if not pd.isna(best_row['std_speedup']) else 0.0,
            'mean_eff': float(best_row['mean_eff']),
        }

# Cargar baseline de round1a para comparación
r1a_csv = None
if last_r1a and Path(last_r1a).exists():
    r1a_csvs = list(Path(last_r1a).glob("csv/bench_round1a.csv"))
    if r1a_csvs:
        r1a_csv = str(r1a_csvs[0])

baseline_speedups = {}
if r1a_csv and Path(r1a_csv).exists():
    r1a_df = pd.read_csv(r1a_csv)
    for col in ['speedup', 'efficiency']:
        r1a_df[col] = pd.to_numeric(r1a_df[col], errors='coerce')
    r1a_summary = r1a_df.groupby(['variant', 'category']).agg(
        mean_speedup=('speedup', 'mean'),
    ).reset_index()
    
    for _, row in r1a_summary.iterrows():
        variant = row['variant']
        category = row['category']
        if variant not in baseline_speedups:
            baseline_speedups[variant] = {}
        baseline_speedups[variant][category] = float(row['mean_speedup'])

# Criterio de pase a Round 2
# +10% sobre 1A en 2+ categorías Y mean_eff ≥ 0.20 en al menos una
round2_decisions = {}

for variant in best_configs.keys():
    categories_improved = []
    max_eff = 0.0
    
    for category, config_data in best_configs[variant].items():
        speedup_1b = config_data['mean_speedup']
        eff_1b = config_data['mean_eff']
        
        max_eff = max(max_eff, eff_1b)
        
        if variant in baseline_speedups and category in baseline_speedups[variant]:
            speedup_1a = baseline_speedups[variant][category]
            improvement_pct = ((speedup_1b - speedup_1a) / speedup_1a * 100) if speedup_1a > 0 else 0
            
            if improvement_pct >= 10.0:
                categories_improved.append(category)
    
    passes = len(categories_improved) >= 2 and max_eff >= 0.20
    
    round2_decisions[variant] = {
        'passes_to_round2': passes,
        'categories_improved_10pct': categories_improved,
        'max_efficiency': float(max_eff),
        'reason': f"Mejoró {len(categories_improved)} categorías (≥10%), max_eff={max_eff:.3f}"
    }

# Guardar
output_dir = Path(artifacts_dir)
best_configs_file = output_dir / "best_configs.json"
with open(best_configs_file, 'w') as f:
    json.dump(best_configs, f, indent=2)

round2_file = output_dir / "round2_decisions.json"
with open(round2_file, 'w') as f:
    json.dump(round2_decisions, f, indent=2)

print("\n=== Mejores Configuraciones por Variante ===")
print(json.dumps(best_configs, indent=2))

print("\n=== Decisiones de Pase a Round 2 ===")
for variant, data in round2_decisions.items():
    status = "✓ PASA" if data['passes_to_round2'] else "✗ NO PASA"
    print(f"{status:12s} {variant:15s} - {data['reason']}")

finalists = [v for v, d in round2_decisions.items() if d['passes_to_round2']]
print(f"\n✓ FINALISTAS para Round 2: {', '.join(finalists)}")

print(f"\nGuardado en:")
print(f"  - {best_configs_file}")
print(f"  - {round2_file}")

# Generar tuning_report.md
report_file = output_dir / "tuning_report.md"
with open(report_file, 'w') as f:
    f.write("# Round 1B - Tuning Report\\n\\n")
    f.write(f"Timestamp: {output_dir.name}\\n\\n")
    f.write("## Sobrevivientes de Round 1A\n\n")
    f.write(f"{', '.join(best_configs.keys())}\n\n")
    
    f.write("## Mejores Configuraciones por Variante\n\n")
    for variant, cats in best_configs.items():
        f.write(f"### {variant}\n\n")
        f.write("| Categoría | Config | Params | Speedup | Std | Efficiency |\n")
        f.write("|-----------|--------|--------|---------|-----|------------|\n")
        for cat, data in cats.items():
            f.write(f"| {cat:6s} | {data['config_id']:10s} | {data['param_spec']:15s} | "
                   f"{data['mean_speedup']:.3f} | {data['std_speedup']:.3f} | {data['mean_eff']:.3f} |\n")
        f.write("\n")
    
    f.write("## Decisiones de Pase a Round 2\n\n")
    for variant, data in round2_decisions.items():
        status = "✓ PASA" if data['passes_to_round2'] else "✗ NO PASA"
        f.write(f"- **{status}** `{variant}`: {data['reason']}\n")
    
    f.write(f"\n## Finalistas\n\n")
    if finalists:
        f.write(f"{', '.join(finalists)}\n")
    else:
        f.write("*Ninguna variante cumplió los criterios.*\n")

print(f"  - {report_file}")

PYTHON_SCRIPT

echo ""
echo "========================================="
echo "ROUND 1B Completado"
echo "========================================="
echo "CSV: $CSV_FILE"
echo "Configs: $ARTIFACTS_DIR/best_configs.json"
echo "Decisiones: $ARTIFACTS_DIR/round2_decisions.json"
echo "Reporte: $ARTIFACTS_DIR/tuning_report.md"
echo ""
echo "Siguiente paso: bash scripts/round2_final.sh"
