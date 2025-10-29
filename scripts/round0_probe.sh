#!/usr/bin/env bash
#
# round0_probe.sh — FASE 0: Exploración de Hiperparámetros
# Ejecuta grid search corto en easy+med, guarda mejores configs en selected.json
#

set -euo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

BUILD_DIR="${BUILD_DIR:-build_bins_opt}"
CIPHER="${CIPHER:-data/cipher.bin}"
SUBSTR="${SUBSTR:-prueba}"
KEY="${KEY:-10000000}"  
P="${P:-8}"
MPIRUN_OVERSUBSCRIBE="${MPIRUN_OVERSUBSCRIBE:-1}"

# Timestamp para artifacts
TS="$(date +%Y%m%d_%H%M%S)"
ARTIFACTS_DIR="artifacts/round0-$TS"
LOGS_DIR="$ARTIFACTS_DIR/logs"
CSV_DIR="$ARTIFACTS_DIR/csv"

mkdir -p "$LOGS_DIR" "$CSV_DIR"

declare -A RANGES
RANGES[easy]="0 2097152"   
RANGES[med]="0 4194304"    


DYNAMIC_B_VALUES=(20000 50000 100000 200000)

ADAPTIVE_T_VALUES=(1.1 1.3 1.5 1.8 2.2)

PERMUTED_R_VALUES=(12345 98765)

# ejecutar y parsear
run_and_parse() {
    local variant=$1
    local category=$2
    local param=$3  
    local param_val=$4  
    
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
        echo "SKIP: $bin not found"
        return 1
    fi
    
    local log_suffix="${param_val}"
    [[ -z "$log_suffix" ]] && log_suffix="default"
    local log_file="$LOGS_DIR/${variant}_${category}_${log_suffix}.log"
    
    local cmd_args="-c $CIPHER -s $SUBSTR -L $L -U $U -k $KEY"
    
    case $variant in
        dynamic)
            [[ -n "$param" ]] && cmd_args="$cmd_args -B ${param#B=}"
            ;;
        adaptive)
            [[ -n "$param" ]] && cmd_args="$cmd_args -T ${param#T=}"
            ;;
        permuted)
            [[ -n "$param" ]] && cmd_args="$cmd_args -R ${param#R=}"
            ;;
    esac
    
    local mpirun_extra=""
    if [[ $MPIRUN_OVERSUBSCRIBE -eq 1 ]]; then
        mpirun_extra="--oversubscribe"
    fi
    
    echo "  Running: $variant $category $param" >&2
    
    if timeout 120 mpirun -np "$P" $mpirun_extra "$bin" $cmd_args > "$log_file" 2>&1; then
        # Parsear resultados
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
                timeout 120 "$BUILD_DIR/bruteforce_seq" --bruteforce -c "$CIPHER" -s "$SUBSTR" \
                    -L "$L" -U "$U" > "$seq_log" 2>&1 || true
                t_seq=$(grep -oP 'Tiempo total.*:\s*\K[0-9.]+' "$seq_log" | head -1)
                [[ -n "$t_seq" ]] && echo "$t_seq" > "$tseq_cache"
            else
                t_seq="0"
            fi
        fi
        
        local speedup="0"
        if [[ -n "$t_seq" && -n "$t_par" ]] && (( $(echo "$t_par > 0" | bc -l 2>/dev/null || echo 0) )); then
            speedup=$(echo "scale=6; $t_seq / $t_par" | bc -l)
        fi
        
        # Retornar CSV line
        echo "$category,$variant,$param,$param_val,$t_seq,$t_par,$speedup,$rank_found,$tests_total,$log_file"
    else
        echo "  TIMEOUT or FAILED" >&2
        return 1
    fi
}

CSV_FILE="$CSV_DIR/bench_round0.csv"
echo "category,variant,param_name,param_value,t_seq_s,t_par_s,speedup,rank_found,tests_total,log_file" > "$CSV_FILE"


echo "========================================="
echo "FASE 0: Exploración de Hiperparámetros"
echo "========================================="
echo "Artifacts: $ARTIFACTS_DIR"
echo "P=$P, KEY=$KEY"
echo ""

echo "=== NAIVE (baseline) ==="
for cat in easy med; do
    if result=$(run_and_parse "naive" "$cat" "" "base"); then
        echo "$result" >> "$CSV_FILE"
    fi
done

echo ""
echo "=== CYCLIC (sin hiperparámetros) ==="
for cat in easy med; do
    if result=$(run_and_parse "cyclic" "$cat" "" "base"); then
        echo "$result" >> "$CSV_FILE"
    fi
done

echo ""
echo "=== DYNAMIC (B grid) ==="
for B in "${DYNAMIC_B_VALUES[@]}"; do
    for cat in easy med; do
        if result=$(run_and_parse "dynamic" "$cat" "B=$B" "B$B"); then
            echo "$result" >> "$CSV_FILE"
        fi
    done
done

echo ""
echo "=== ADAPTIVE (T grid) ==="
for T in "${ADAPTIVE_T_VALUES[@]}"; do
    for cat in easy med; do
        if result=$(run_and_parse "adaptive" "$cat" "T=$T" "T$T"); then
            echo "$result" >> "$CSV_FILE"
        fi
    done
done

echo ""
echo "=== PERMUTED (R grid) ==="
for R in "${PERMUTED_R_VALUES[@]}"; do
    for cat in easy med; do
        if result=$(run_and_parse "permuted" "$cat" "R=$R" "R$R"); then
            echo "$result" >> "$CSV_FILE"
        fi
    done
done


echo ""
echo "========================================="
echo "Analizando resultados..."
echo "========================================="

python3 - "$CSV_DIR" "$ARTIFACTS_DIR" <<'PYTHON_SCRIPT'
import pandas as pd
import json
import sys
from pathlib import Path

csv_dir = sys.argv[1]
artifacts_dir = sys.argv[2]

csv_file = Path(csv_dir) / "bench_round0.csv"
if not csv_file.exists():
    print(f"ERROR: {csv_file} not found")
    sys.exit(1)

df = pd.read_csv(csv_file)
df['speedup'] = pd.to_numeric(df['speedup'], errors='coerce')
df['t_par_s'] = pd.to_numeric(df['t_par_s'], errors='coerce')

# Filtrar invalid
df = df[df['speedup'] > 0].copy()

# Seleccionar mejor configuración por variante y categoría
selections = {}

for variant in df['variant'].unique():
    selections[variant] = {}
    vdf = df[df['variant'] == variant]
    
    for category in vdf['category'].unique():
        cdf = vdf[vdf['category'] == category]
        
        if len(cdf) == 0:
            continue
        
        # Criterio: máximo speedup, desempate con menor std si hay réplicas
        best_idx = cdf['speedup'].idxmax()
        best_row = cdf.loc[best_idx]
        
        selections[variant][category] = {
            'param_name': str(best_row['param_name']),
            'param_value': str(best_row['param_value']),
            'speedup': float(best_row['speedup']),
            't_par_s': float(best_row['t_par_s']),
            'efficiency': float(best_row['speedup'] / 8.0)  # P=8
        }

# Guardar
output_file = Path(artifacts_dir) / "selected.json"
with open(output_file, 'w') as f:
    json.dump(selections, f, indent=2)

print(f"\n✓ Mejores configuraciones guardadas en: {output_file}")
print("\nResumen:")
print(json.dumps(selections, indent=2))

PYTHON_SCRIPT

echo ""
echo "========================================="
echo "FASE 0 Completada"
echo "========================================="
echo "CSV: $CSV_FILE"
echo "Selección: $ARTIFACTS_DIR/selected.json"
echo ""
echo "Siguiente paso: bash scripts/round1a_algorithmic.sh"
