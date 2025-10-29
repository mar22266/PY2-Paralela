#!/usr/bin/env bash
# ============================================================================
# quick_comparison.sh - Comparación rápida baseline vs optimizado
# ============================================================================
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASELINE_BIN="$PROJ_DIR/build_bins_opt/bruteforce_mpi_cyclic"
OPT_BIN="$PROJ_DIR/opt/build/bruteforce_mpi_cyclic_opt"

CIPHER="$PROJ_DIR/data/cipher.bin"
SUBSTR="es una prueba de"
CATEGORY="${CATEGORY:-hard}"

# Ranges
case "$CATEGORY" in
  easy) L=0; U=2097152 ;;    # 2^21
  med)  L=0; U=4194304 ;;    # 2^22
  hard) L=0; U=8388608 ;;    # 2^23
  *) echo "ERROR: CATEGORY debe ser easy/med/hard"; exit 1 ;;
esac

P_VALUES="${P_VALUES:-4 8 16}"
REPS="${REPS:-3}"

# Optimization parameters to test
B_VALUES="${B_VALUES:-20000 50000 100000}"
SYNC_FREQ_VALUES="${SYNC_FREQ_VALUES:-4 8 16}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="$PROJ_DIR/artifacts/comparison_opt_$TIMESTAMP"
mkdir -p "$OUT_DIR"/{logs,csv}

echo "============================================"
echo "  Comparación Baseline vs Optimizado"
echo "============================================"
echo "Timestamp:  $TIMESTAMP"
echo "Category:   $CATEGORY (range [$L, $U))"
echo "P values:   $P_VALUES"
echo "Reps:       $REPS"
echo "Output:     $OUT_DIR"
echo "============================================"
echo

# Check binaries
if [[ ! -x "$BASELINE_BIN" ]]; then
    echo "ERROR: No existe $BASELINE_BIN"
    echo "Compila: bash scripts/compile_bins_opt.sh"
    exit 1
fi

if [[ ! -x "$OPT_BIN" ]]; then
    echo "ERROR: No existe $OPT_BIN"
    echo "Compila: bash opt/scripts/compile_optimized.sh"
    exit 1
fi

# CSV header
CSV="$OUT_DIR/csv/comparison.csv"
echo "variant,P,B,sync_freq,rep,t_par_s,tests_total,rank_found" > "$CSV"

total_runs=$((
  $(echo $P_VALUES | wc -w) * 
  (1 + $(echo $B_VALUES | wc -w) * $(echo $SYNC_FREQ_VALUES | wc -w)) * 
  REPS
))
current=0

# Run baseline
for P in $P_VALUES; do
    for rep in $(seq 1 $REPS); do
        current=$((current + 1))
        
        logfile="$OUT_DIR/logs/baseline_P${P}_rep${rep}.log"
        echo "[$current/$total_runs] baseline | P=$P | rep=$rep"
        
        mpirun --oversubscribe -np "$P" \
          "$BASELINE_BIN" \
          -c "$CIPHER" -s "$SUBSTR" -L "$L" -U "$U" \
          > "$logfile" 2>&1 || echo "  ⚠ Failed"
        
        # Extract metrics
        t_par=$(grep -E "Tiempo total \(max rank\)" "$logfile" | awk '{print $(NF-1); exit}' || echo "")
        tests=$(grep -E "tests_total:" "$logfile" | awk '{print $2; exit}' || echo "")
        rank=$(grep -E "rank_found:" "$logfile" | awk '{print $2; exit}' || echo "")
        
        echo "baseline,$P,,,$rep,${t_par:-},${tests:-},${rank:-}" >> "$CSV"
        
        sleep 0.2
    done
done

# Run optimized with different parameters
for P in $P_VALUES; do
    for B in $B_VALUES; do
        for sync_freq in $SYNC_FREQ_VALUES; do
            for rep in $(seq 1 $REPS); do
                current=$((current + 1))
                
                logfile="$OUT_DIR/logs/opt_P${P}_B${B}_sync${sync_freq}_rep${rep}.log"
                echo "[$current/$total_runs] optimized | P=$P | B=$B | sync=$sync_freq | rep=$rep"
                
                mpirun --oversubscribe -np "$P" \
                  "$OPT_BIN" \
                  -c "$CIPHER" -s "$SUBSTR" -L "$L" -U "$U" \
                  -B "$B" --sync-freq "$sync_freq" \
                  > "$logfile" 2>&1 || echo "  ⚠ Failed"
                
                # Extract metrics
                t_par=$(grep -E "Tiempo total \(max rank\)" "$logfile" | awk '{print $(NF-1); exit}' || echo "")
                tests=$(grep -E "tests_total:" "$logfile" | awk '{print $2; exit}' || echo "")
                rank=$(grep -E "rank_found:" "$logfile" | awk '{print $2; exit}' || echo "")
                
                echo "optimized,$P,$B,$sync_freq,$rep,${t_par:-},${tests:-},${rank:-}" >> "$CSV"
                
                sleep 0.2
            done
        done
    done
done

echo
echo "✓ Todas las ejecuciones completadas"
echo

# Analyze with Python
python3 - "$CSV" "$OUT_DIR" <<'PYTHON_SCRIPT'
import sys
import pandas as pd
import numpy as np
from pathlib import Path

csv_file = Path(sys.argv[1])
out_dir = Path(sys.argv[2])

df = pd.read_csv(csv_file)

# Filter valid rows
df = df[df['t_par_s'].notna() & (df['t_par_s'] > 0)]

if df.empty:
    print("⚠ No hay datos válidos")
    sys.exit(0)

# Separate baseline and optimized
baseline = df[df['variant'] == 'baseline'].copy()
optimized = df[df['variant'] == 'optimized'].copy()

# Group baseline by P
baseline_grouped = baseline.groupby('P').agg({
    't_par_s': ['mean', 'std']
}).reset_index()
baseline_grouped.columns = ['P', 't_baseline_mean', 't_baseline_std']

# Group optimized by (P, B, sync_freq)
optimized_grouped = optimized.groupby(['P', 'B', 'sync_freq']).agg({
    't_par_s': ['mean', 'std']
}).reset_index()
optimized_grouped.columns = ['P', 'B', 'sync_freq', 't_opt_mean', 't_opt_std']

# Merge with baseline
comparison = optimized_grouped.merge(baseline_grouped, on='P')

# Calculate speedup improvement
comparison['speedup_ratio'] = comparison['t_baseline_mean'] / comparison['t_opt_mean']
comparison['improvement_pct'] = (comparison['speedup_ratio'] - 1.0) * 100.0

# Sort by improvement
comparison = comparison.sort_values('improvement_pct', ascending=False)

# Save
summary_csv = out_dir / 'csv' / 'comparison_summary.csv'
comparison.to_csv(summary_csv, index=False)

# Print results
print("\n" + "="*80)
print("  COMPARISON SUMMARY")
print("="*80)
print(comparison[[
    'P', 'B', 'sync_freq',
    't_baseline_mean', 't_opt_mean',
    'speedup_ratio', 'improvement_pct'
]].to_string(index=False))
print("="*80 + "\n")

# Best configs per P
print("🏆 BEST CONFIGS POR P:\n")
for P in sorted(comparison['P'].unique()):
    p_df = comparison[comparison['P'] == P].nlargest(1, 'improvement_pct')
    if not p_df.empty:
        row = p_df.iloc[0]
        print(f"  P={int(P):2d}  →  B={int(row['B']):6d}, sync_freq={int(row['sync_freq']):2d}  →  "
              f"{row['t_baseline_mean']:.5f}s → {row['t_opt_mean']:.5f}s  "
              f"(+{row['improvement_pct']:.1f}% faster)")
print()

# Overall best
if not comparison.empty:
    best = comparison.iloc[0]
    print(f"🥇 OVERALL BEST:")
    print(f"   P={int(best['P'])}, B={int(best['B'])}, sync_freq={int(best['sync_freq'])}")
    print(f"   {best['t_baseline_mean']:.5f}s → {best['t_opt_mean']:.5f}s")
    print(f"   Improvement: +{best['improvement_pct']:.1f}%")
print()

PYTHON_SCRIPT

echo "============================================"
echo "  ✓ COMPARACIÓN COMPLETADA"
echo "============================================"
echo "Output:  $OUT_DIR"
echo "CSV raw: $CSV"
echo "Summary: $OUT_DIR/csv/comparison_summary.csv"
echo "============================================"
echo
echo "💡 Ver resultados:"
echo "   cat $OUT_DIR/csv/comparison_summary.csv | column -t -s,"
echo
