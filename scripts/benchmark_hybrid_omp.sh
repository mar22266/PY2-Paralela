#!/usr/bin/env bash
# ==================================================================
# Benchmark híbrido MPI+OpenMP
# Compara cyclic puro vs cyclic+OpenMP con diferentes configuraciones
# ==================================================================
set -Eeuo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HYBRID_BIN="$PROJ_DIR/build_bins_opt/bruteforce_mpi_cyclic_omp"
PURE_BIN="$PROJ_DIR/build_bins_opt/bruteforce_mpi_cyclic"
CIPHER="$PROJ_DIR/data/cipher.bin"
NEEDLE="es una prueba de"

# Configuración del benchmark
L=0
U=8388608  # 2^23 = ~8M keys (ajustable según hardware)

# Crear directorio de artifacts
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ARTIFACTS_DIR="$PROJ_DIR/artifacts/hybrid_omp_benchmark_${TIMESTAMP}"
mkdir -p "$ARTIFACTS_DIR/logs"
CSV_OUT="$ARTIFACTS_DIR/benchmark_results.csv"

echo "════════════════════════════════════════════════════════════"
echo "  Benchmark Híbrido MPI+OpenMP"
echo "════════════════════════════════════════════════════════════"
echo "Artifacts: $ARTIFACTS_DIR"
echo "Rango: [$L, $U)"
echo ""

# Verificar binarios
if [[ ! -x "$HYBRID_BIN" ]]; then
    echo "✘ Error: binario híbrido no encontrado o no ejecutable: $HYBRID_BIN"
    echo "  Ejecuta: bash scripts/compile_hybrid_omp.sh"
    exit 1
fi

if [[ ! -x "$PURE_BIN" ]]; then
    echo "✘ Error: binario MPI puro no encontrado: $PURE_BIN"
    echo "  Ejecuta: bash scripts/compile_bins_opt.sh"
    exit 1
fi

if [[ ! -f "$CIPHER" ]]; then
    echo "✘ Error: cipher.bin no encontrado: $CIPHER"
    echo "  Ejecuta primero la versión secuencial para generar el archivo cifrado"
    exit 1
fi

# Inicializar CSV
echo "variant,P,OMP_THREADS,total_workers,t_par_s,speedup_vs_seq,efficiency,log_file" > "$CSV_OUT"

# Baseline secuencial (una sola vez)
echo "→ Midiendo baseline secuencial..."
SEQ_BIN="$PROJ_DIR/build_bins_opt/bruteforce_seq"
if [[ -x "$SEQ_BIN" ]]; then
    SEQ_LOG="$ARTIFACTS_DIR/logs/seq_baseline.log"
    "$SEQ_BIN" --bruteforce -c "$CIPHER" -s "$NEEDLE" -L "$L" -U "$U" > "$SEQ_LOG" 2>&1 || true
    
    # Extraer tiempo secuencial
    T_SEQ=$(grep -oP 'Tiempo.*?:\s*\K[0-9.]+' "$SEQ_LOG" | head -1 || echo "0")
    echo "  t_seq = ${T_SEQ}s"
else
    echo "⚠ Advertencia: binario secuencial no encontrado, usando t_seq=3.056 (valor por defecto)"
    T_SEQ=3.056193
fi
echo ""

# Función para ejecutar benchmark
run_benchmark() {
    local variant="$1"
    local bin="$2"
    local P="$3"
    local omp_threads="$4"
    local total_workers=$((P * omp_threads))
    
    local log_file="$ARTIFACTS_DIR/logs/${variant}_P${P}_T${omp_threads}.log"
    
    echo "→ Ejecutando: $variant | P=$P | OMP=$omp_threads | Total=$total_workers"
    
    # Configurar OpenMP
    export OMP_NUM_THREADS="$omp_threads"
    
    # Ejecutar
    if mpirun -np "$P" "$bin" \
        -c "$CIPHER" \
        -s "$NEEDLE" \
        -L "$L" \
        -U "$U" > "$log_file" 2>&1; then
        
        # Extraer tiempo paralelo
        t_par=$(grep -oP 'Tiempo total.*?:\s*\K[0-9.]+' "$log_file" | head -1 || echo "0")
        
        if [[ $(echo "$t_par > 0" | bc -l) -eq 1 ]]; then
            speedup=$(echo "scale=4; $T_SEQ / $t_par" | bc -l)
            efficiency=$(echo "scale=4; $speedup / $total_workers" | bc -l)
            
            echo "  t_par = ${t_par}s | speedup = ${speedup}x | eff = ${efficiency}"
            echo "$variant,$P,$omp_threads,$total_workers,$t_par,$speedup,$efficiency,$log_file" >> "$CSV_OUT"
        else
            echo "  ⚠ Error: no se pudo extraer tiempo del log"
        fi
    else
        echo "  ✘ Ejecución falló (ver log: $log_file)"
    fi
    echo ""
}

# ═══════════════════════════════════════════════════════════════
# Configuraciones de benchmark
# ═══════════════════════════════════════════════════════════════

echo "════════════════════════════════════════════════════════════"
echo "  FASE 1: Baseline MPI Puro (sin OpenMP)"
echo "════════════════════════════════════════════════════════════"
for P in 2 4 8; do
    run_benchmark "mpi_cyclic" "$PURE_BIN" "$P" 1
done

echo "════════════════════════════════════════════════════════════"
echo "  FASE 2: Híbrido MPI+OpenMP (configuraciones balanceadas)"
echo "════════════════════════════════════════════════════════════"

# P=2, OMP=2,4 (total 4,8 workers)
run_benchmark "mpi_omp_cyclic" "$HYBRID_BIN" 2 2
run_benchmark "mpi_omp_cyclic" "$HYBRID_BIN" 2 4

# P=4, OMP=2 (total 8 workers)
run_benchmark "mpi_omp_cyclic" "$HYBRID_BIN" 4 2

# P=8, OMP=1 (total 8 workers - equivalente a MPI puro)
run_benchmark "mpi_omp_cyclic" "$HYBRID_BIN" 8 1

echo "════════════════════════════════════════════════════════════"
echo "  FASE 3: Configuraciones extremas (si hay cores suficientes)"
echo "════════════════════════════════════════════════════════════"

# P=1, OMP=4,8 (híbrido degenerado - solo OpenMP)
run_benchmark "mpi_omp_cyclic" "$HYBRID_BIN" 1 4
run_benchmark "mpi_omp_cyclic" "$HYBRID_BIN" 1 8

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Benchmark completado"
echo "════════════════════════════════════════════════════════════"
echo "Resultados: $CSV_OUT"
echo ""

# Generar reporte resumido
echo "→ Generando reporte..."
REPORT_FILE="$ARTIFACTS_DIR/REPORT.md"

cat > "$REPORT_FILE" <<'EOFHEADER'
# Benchmark Híbrido MPI+OpenMP - Resultados

## Configuración

EOFHEADER

cat >> "$REPORT_FILE" <<EOFCONFIG
- **Rango de llaves:** [$L, $U) ($(echo "scale=2; ($U - $L) / 1000000" | bc -l)M keys)
- **Tiempo secuencial:** ${T_SEQ}s
- **Cipher:** \`$CIPHER\`
- **Timestamp:** $TIMESTAMP

## Resultados

### Tabla completa

\`\`\`csv
$(cat "$CSV_OUT")
\`\`\`

### Análisis por configuración

EOFCONFIG

# Análisis simple con awk
awk -F',' 'NR>1 {
    if ($6 > max_speedup) {
        max_speedup = $6
        best_config = $1 " (P=" $2 ", OMP=" $3 ")"
    }
    if ($1 == "mpi_omp_cyclic") {
        hybrid_sum += $6
        hybrid_count++
    } else if ($1 == "mpi_cyclic") {
        pure_sum += $6
        pure_count++
    }
}
END {
    print "#### Mejor configuración" >> "'"$REPORT_FILE"'"
    print "- **" best_config "**: " max_speedup "x speedup" >> "'"$REPORT_FILE"'"
    print "" >> "'"$REPORT_FILE"'"
    
    if (pure_count > 0 && hybrid_count > 0) {
        print "#### Comparación promedio" >> "'"$REPORT_FILE"'"
        print "- **MPI puro:** " (pure_sum/pure_count) "x speedup promedio (" pure_count " configs)" >> "'"$REPORT_FILE"'"
        print "- **MPI+OpenMP:** " (hybrid_sum/hybrid_count) "x speedup promedio (" hybrid_count " configs)" >> "'"$REPORT_FILE"'"
        improvement = ((hybrid_sum/hybrid_count) / (pure_sum/pure_count) - 1) * 100
        print "- **Mejora híbrido:** " improvement "%" >> "'"$REPORT_FILE"'"
    }
}' "$CSV_OUT"

cat >> "$REPORT_FILE" <<'EOFFOOTER'

## Interpretación

### Speedup esperado

- **Ideal (P=2, OMP=2):** ~4x con 4 cores
- **Ideal (P=4, OMP=2):** ~8x con 8 cores
- **Overhead típico:** 10-20% por sincronización

### Eficiencia

- **>75%:** Excelente escalabilidad
- **50-75%:** Buena escalabilidad
- **<50%:** Overhead significativo (revisar balance MPI/OpenMP)

### Configuraciones recomendadas

1. **Homogéneo (cores iguales por nodo):** P=nodos, OMP=cores/nodo
2. **Heterogéneo:** Usar --map-by node y ajustar OMP por capacidad
3. **Memoria compartida:** Favorece OpenMP (P=1, OMP=max)
4. **Memoria distribuida:** Favorece MPI (P=max, OMP=1)

## Logs

Ver logs individuales en: `logs/`
EOFFOOTER

echo "Reporte: $REPORT_FILE"
echo ""
echo "Para visualizar:"
echo "  cat $REPORT_FILE"
echo "  column -t -s',' $CSV_OUT | less -S"
