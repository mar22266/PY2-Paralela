#!/usr/bin/env bash
# Benchmark con range más grande (sin early-stop) para reducir ruido

set -euo pipefail
cd "$(dirname "$0")/.."

echo "=========================================="
echo "  Benchmark LARGO (sin early-stop)"
echo "=========================================="
echo ""

CIPHER="data/cipher.bin"
SUBSTR="xxxNOEXISTE"  # No encontrará key, procesará todo el range
L=0
U=5000000  # 5M keys
REPS=3

echo "Config: 5M keys, no key (sin early-stop), 3 reps"
echo ""

BASELINE_SEQ="build_baseline_O2/bruteforce_seq"
OPT_SEQ="build_bins_opt/bruteforce_seq"

echo "→ Secuencial (más estable, sin MPI noise)"
echo ""

times_baseline=()
times_opt=()

for rep in $(seq 1 $REPS); do
    echo "  Rep $rep/$REPS:"
    
    # Baseline
    printf "    Baseline -O2... "
    time_baseline=$("$BASELINE_SEQ" --bruteforce -c "$CIPHER" -s "$SUBSTR" -L $L -U $U 2>&1 | grep "Tiempo total" | awk '{print $(NF-1)}')
    times_baseline+=($time_baseline)
    printf "%.4fs | " "$time_baseline"
    
    # Optimized
    printf "Optimized... "
    time_opt=$("$OPT_SEQ" --bruteforce -c "$CIPHER" -s "$SUBSTR" -L $L -U $U 2>&1 | grep "Tiempo total" | awk '{print $(NF-1)}')
    times_opt+=($time_opt)
    printf "%.4fs " "$time_opt"
    
    # Speedup
    speedup=$(echo "scale=3; $time_baseline / $time_opt" | bc -l)
    printf "→ %.3fx\n" "$speedup"
done

echo ""
echo "=========================================="
echo "  ANÁLISIS"
echo "=========================================="

# Calcular promedios
sum_baseline=0
for t in "${times_baseline[@]}"; do
    sum_baseline=$(echo "$sum_baseline + $t" | bc -l)
done
avg_baseline=$(echo "scale=6; $sum_baseline / $REPS" | bc -l)

sum_opt=0
for t in "${times_opt[@]}"; do
    sum_opt=$(echo "$sum_opt + $t" | bc -l)
done
avg_opt=$(echo "scale=6; $sum_opt / $REPS" | bc -l)

speedup=$(echo "scale=3; $avg_baseline / $avg_opt" | bc -l)
improvement=$(echo "scale=2; ($speedup - 1) * 100" | bc -l)

echo ""
echo "Baseline (-O2):     ${avg_baseline}s promedio"
echo "Optimizado (flags): ${avg_opt}s promedio"
echo ""
echo "Speedup: ${speedup}x (${improvement}% mejora)"
echo ""

if (( $(echo "$speedup > 1.02" | bc -l) )); then
    echo "✅ Mejora significativa con flags agresivas"
elif (( $(echo "$speedup > 0.98" | bc -l) )); then
    echo "⚠️  Mejora marginal o neutral"
else
    echo "❌ Regresión - flags perjudican performance"
fi
echo ""
