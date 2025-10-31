set -euo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

BUILD_DIR="${BUILD_DIR:-build_bins_opt}"
CIPHER="${CIPHER:-data/cipher.bin}"
SUBSTR="${SUBSTR:-prueba}"
KEY="${KEY:-10000000}"
P_VALUES="${P_VALUES:-8}"  
MPIRUN_OVERSUBSCRIBE="${MPIRUN_OVERSUBSCRIBE:-1}"
REPS="${REPS:-5}"  

# Timestamp
TS="$(date +%Y%m%d_%H%M%S)"
ARTIFACTS_DIR="artifacts/round2-$TS"
LOGS_DIR="$ARTIFACTS_DIR/logs"
CSV_DIR="$ARTIFACTS_DIR/csv"
PLOTS_DIR="$ARTIFACTS_DIR/plots"

mkdir -p "$LOGS_DIR" "$CSV_DIR" "$PLOTS_DIR"

# Rangos
declare -A RANGES
RANGES[easy]="0 2097152"
RANGES[med]="0 4194304"
RANGES[hard]="0 8388608"


LAST_R1B=$(ls -td artifacts/round1b-* 2>/dev/null | head -1)

if [[ -z "$LAST_R1B" || ! -f "$LAST_R1B/best_configs.json" ]]; then
    echo "ERROR: No se encontró Round 1B o best_configs.json"
    echo "Ejecuta primero: bash scripts/round1b_tuning.sh"
    exit 1
fi

echo "ROUND 2: Competencia Final"
echo "Configuraciones desde: $LAST_R1B/best_configs.json"
echo "P values: $P_VALUES"
echo "REPS: $REPS"
echo "Artifacts: $ARTIFACTS_DIR"
echo ""

# Leer finalistas
FINALISTS=$(python3 -c "
import json
with open('$LAST_R1B/round2_decisions.json') as f:
    data = json.load(f)
finalists = [v for v, d in data.items() if d['passes_to_round2']]
print(' '.join(finalists))
")

if [[ -z "$FINALISTS" ]]; then
    echo "ERROR: No hay finalistas. Verifica Round 1B."
    exit 1
fi

echo "Finalistas: $FINALISTS"
echo ""


CSV_FILE="$CSV_DIR/bench_round2.csv"
echo "P,category,variant,config_id,param_spec,rep,t_seq_s,t_par_s,speedup,efficiency,rank_found,tests_total,log_file" > "$CSV_FILE"


run_optimal() {
    local P=$1
    local variant=$2
    local category=$3
    local config_id=$4
    local param_spec=$5
    local rep=$6
    
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
    
    local log_file="$LOGS_DIR/${variant}_P${P}_${category}_rep${rep}.log"
    local cmd_args="-c $CIPHER -s $SUBSTR -L $L -U $U -k $KEY $param_spec"
    
    local mpirun_extra=""
    [[ $MPIRUN_OVERSUBSCRIBE -eq 1 ]] && mpirun_extra="--oversubscribe"
    
    echo "  [$rep/$REPS] P=$P $variant $category"
    
    if timeout 300 mpirun -np "$P" $mpirun_extra "$bin" $cmd_args > "$log_file" 2>&1; then
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
                timeout 300 "$BUILD_DIR/bruteforce_seq" --bruteforce -c "$CIPHER" -s "$SUBSTR" \
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
        
        echo "$P,$category,$variant,$config_id,$param_spec,$rep,$t_seq,$t_par,$speedup,$efficiency,$rank_found,$tests_total,$log_file" >> "$CSV_FILE"
    else
        echo "  TIMEOUT/FAILED"
        return 1
    fi
}


declare -A OPTIMAL_CONFIGS

while IFS= read -r line; do
    OPTIMAL_CONFIGS["$line"]=$(echo "$line")
done < <(python3 -c "
import json
with open('$LAST_R1B/best_configs.json') as f:
    configs = json.load(f)
for variant, cats in configs.items():
    for category, data in cats.items():
        key = f'{variant}:{category}'
        print(f\"{key}|{data['config_id']}|{data['param_spec']}\")
")

for P in $P_VALUES; do
    echo ""
    echo "P = $P"
    
    for variant in $FINALISTS; do
        echo ""
        echo "=== Variante: $variant ==="
        
        for category in easy med hard; do
            # Obtener config óptima
            key="${variant}:${category}"
            config_line=""
            
            # Buscar en configs
            for ckey in "${!OPTIMAL_CONFIGS[@]}"; do
                if [[ "$ckey" == "$key" ]]; then
                    config_line="${OPTIMAL_CONFIGS[$ckey]}"
                    break
                fi
            done
            
            if [[ -z "$config_line" ]]; then
                echo "  ADVERTENCIA: No se encontró config óptima para $key, usando default"
                config_id="default"
                param_spec=""
            else
                IFS='|' read -r _ config_id param_spec <<< "$config_line"
            fi
            
            # Ejecutar réplicas
            for rep in $(seq 1 $REPS); do
                run_optimal "$P" "$variant" "$category" "$config_id" "$param_spec" "$rep" || true
            done
        done
    done
done


cp "$CSV_FILE" "logs/bench_round2-$TS.csv"

echo ""
echo "Generando análisis y gráficas..."

python3 - "$CSV_FILE" "$ARTIFACTS_DIR" <<'PYTHON_SCRIPT'
import pandas as pd
import numpy as np
import json
from pathlib import Path
import sys

csv_path = Path(sys.argv[1])
artifacts_dir = sys.argv[2]

df = pd.read_csv(csv_path)

# Coerce numeric
for col in ['P', 't_seq_s', 't_par_s', 'speedup', 'efficiency']:
    df[col] = pd.to_numeric(df[col], errors='coerce')

df = df[(df['speedup'] > 0) & (df['t_par_s'] > 0)].copy()

# Resumen por P, variant, category
summary = df.groupby(['P', 'variant', 'category']).agg(
    reps=('speedup', 'count'),
    mean_speedup=('speedup', 'mean'),
    std_speedup=('speedup', 'std'),
    q25_speedup=('speedup', lambda x: x.quantile(0.25)),
    q75_speedup=('speedup', lambda x: x.quantile(0.75)),
    mean_eff=('efficiency', 'mean'),
    std_eff=('efficiency', 'std'),
).reset_index()

summary['iqr_speedup'] = summary['q75_speedup'] - summary['q25_speedup']

print("\n=== Resumen Round 2 ===")
print(summary.to_string(index=False))

# Guardar summary
output_dir = Path(artifacts_dir)
summary_file = output_dir / "csv" / "round2_summary.csv"
summary.to_csv(summary_file, index=False)

# Análisis de Ganadores
winners = {}
for P in summary['P'].unique():
    winners[int(P)] = {}
    pdf = summary[summary['P'] == P]
    
    for category in pdf['category'].unique():
        cdf = pdf[pdf['category'] == category]
        
        # Ganador: mejor mean_speedup
        best_idx = cdf['mean_speedup'].idxmax()
        winner_row = cdf.loc[best_idx]
        
        winners[int(P)][category] = {
            'variant': str(winner_row['variant']),
            'mean_speedup': float(winner_row['mean_speedup']),
            'std_speedup': float(winner_row['std_speedup']) if not pd.isna(winner_row['std_speedup']) else 0.0,
            'mean_eff': float(winner_row['mean_eff']),
            'iqr_speedup': float(winner_row['iqr_speedup']) if not pd.isna(winner_row['iqr_speedup']) else 0.0,
        }

winners_file = output_dir / "winners.json"
with open(winners_file, 'w') as f:
    json.dump(winners, f, indent=2)

print("\n=== GANADORES por P y Categoría ===")
for P, cats in winners.items():
    print(f"\nP = {P}:")
    for cat, data in cats.items():
        print(f"  {cat:6s}: {data['variant']:15s} speedup={data['mean_speedup']:.3f}±{data['std_speedup']:.3f} "
              f"eff={data['mean_eff']:.3f} IQR={data['iqr_speedup']:.3f}")

# Generar reporte markdown
report_file = output_dir / "final_report.md"
with open(report_file, 'w') as f:
    f.write("# Round 2 - Final Competition Report\\n\\n")
    f.write(f"Timestamp: {output_dir.name}\\n\\n")
    
    f.write("## Finalistas\\n\\n")
    finalists = df['variant'].unique()
    f.write(f"{', '.join(finalists)}\n\n")
    
    f.write("## Configuraciones Utilizadas\n\n")
    f.write("*(Óptimas de Round 1B)*\n\n")
    for variant in finalists:
        vdf = df[df['variant'] == variant]
        f.write(f"### {variant}\n\n")
        f.write("| Categoría | Config | Params |\n")
        f.write("|-----------|--------|--------|\n")
        for _, row in vdf[['category', 'config_id', 'param_spec']].drop_duplicates().iterrows():
            f.write(f"| {row['category']:6s} | {row['config_id']:10s} | {row['param_spec']:15s} |\n")
        f.write("\n")
    
    f.write("## Resultados por P\n\n")
    for P in sorted(summary['P'].unique()):
        f.write(f"### P = {int(P)}\n\n")
        pdf = summary[summary['P'] == P]
        f.write("| Variante | Categoría | Speedup (mean±std) | IQR | Efficiency |\n")
        f.write("|----------|-----------|-------------------|-----|------------|\n")
        for _, row in pdf.iterrows():
            f.write(f"| {row['variant']:10s} | {row['category']:6s} | "
                   f"{row['mean_speedup']:.3f}±{row['std_speedup']:.3f} | "
                   f"{row['iqr_speedup']:.3f} | {row['mean_eff']:.3f} |\n")
        f.write("\n")
    
    f.write("## Ganadores\n\n")
    for P, cats in winners.items():
        f.write(f"### P = {P}\n\n")
        for cat, data in cats.items():
            f.write(f"- **{cat}**: `{data['variant']}` - speedup={data['mean_speedup']:.3f}±{data['std_speedup']:.3f}, "
                   f"eff={data['mean_eff']:.3f}\n")
        f.write("\n")
    
    f.write("## Conclusiones\n\n")
    f.write("*(Completar manualmente con interpretaciones)*\n\n")

print(f"\nArchivos generados:")
print(f"  - CSV completo: {csv_path}")
print(f"  - Resumen: {summary_file}")
print(f"  - Ganadores: {winners_file}")
print(f"  - Reporte: {report_file}")

# Nota: gráficas requieren matplotlib, se pueden agregar después

PYTHON_SCRIPT

echo ""
echo "ROUND 2 Completado"
echo "CSV: $CSV_FILE"
echo "Resumen: $ARTIFACTS_DIR/csv/round2_summary.csv"
echo "Ganadores: $ARTIFACTS_DIR/winners.json"
echo "Reporte: $ARTIFACTS_DIR/final_report.md"
echo ""
echo "🏆 Competencia finalizada. Revisa el reporte para conclusiones."
