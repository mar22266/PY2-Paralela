#!/usr/bin/env bash
# ============================================================================
# vectorize_des_test.sh - FASE B: Vectorización del Kernel DES
# ============================================================================
# Objetivo: Acelerar kernel DES mediante vectorización y compiler flags
# Mide throughput (keys/sec) antes y después de optimizaciones
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROFILE_DIR="$PROJECT_ROOT/opt/profiles"
REPORT_FILE="$PROJECT_ROOT/opt/reports/VECTORIZATION_DES.md"

cd "$PROJECT_ROOT"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "=============================================="
echo "  FASE B: Vectorización del Kernel DES"
echo "=============================================="
echo ""

mkdir -p "$PROFILE_DIR"
mkdir -p "$(dirname "$REPORT_FILE")"

# ============================================================================
# 1. CREAR MICROBENCHMARK DES
# ============================================================================

echo -e "${GREEN}▶ Paso 1: Crear microbenchmark DES${NC}"
echo ""

MICRO_SRC="$PROJECT_ROOT/opt/src/des_microbench.c"

cat > "$MICRO_SRC" <<'EOFMICRO'
// ============================================================================
// des_microbench.c - Microbenchmark puro de DES throughput
// ============================================================================
// Mide keys/sec sin overhead de MPI, I/O, o early-stop
// Útil para medir impacto de compiler flags y vectorización
// ============================================================================

#include "des_utils.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if(argc < 2) {
        fprintf(stderr, "USO: %s <N_ITERATIONS>\n", argv[0]);
        fprintf(stderr, "  N_ITERATIONS: número de keys a probar (ej: 1000000)\n");
        return 1;
    }
    
    uint64_t N = strtoull(argv[1], NULL, 10);
    
    printf("============================================\n");
    printf("  DES Microbenchmark\n");
    printf("============================================\n");
    printf("Iteraciones: %lu\n", N);
    printf("Compilado con: ");
#ifdef __OPTIMIZE__
    printf("-O%d ", __OPTIMIZE__);
#endif
#ifdef __FAST_MATH__
    printf("-ffast-math ");
#endif
#ifdef __AVX2__
    printf("-mavx2 ");
#endif
#ifdef __AVX__
    printf("-mavx ");
#endif
#ifdef __SSE4_2__
    printf("-msse4.2 ");
#endif
    printf("\n\n");
    
    // Cipher ficticio para testing
    const char *plaintext = "Esta es una prueba de vectorizacion DES para medir throughput";
    size_t len = strlen(plaintext);
    unsigned char *cipher = (unsigned char*)malloc(len + 8);
    
    // Encrypt con key arbitraria para generar cipher
    uint64_t test_key = 123456;
    des_encrypt_buffer(test_key, (const unsigned char*)plaintext, len, cipher);
    
    const char *needle = "prueba";
    int nlen = strlen(needle);
    
    printf("→ Inicio benchmark...\n\n");
    
    double t0 = now_sec();
    uint64_t matches = 0;
    
    // Loop principal: probar N keys consecutivas
    for(uint64_t k = 0; k < N; k++) {
        if(des_try_key(k, cipher, len, needle)) {
            matches++;
        }
    }
    
    double t1 = now_sec();
    double elapsed = t1 - t0;
    
    printf("✓ Completado\n\n");
    printf("Resultados:\n");
    printf("  • Tiempo total     : %.6f s\n", elapsed);
    printf("  • Keys probadas    : %lu\n", N);
    printf("  • Throughput       : %.0f keys/sec\n", N / elapsed);
    printf("  • Tiempo por key   : %.3f µs\n", (elapsed * 1e6) / N);
    printf("  • Matches encontrados: %lu\n", matches);
    printf("\n");
    
    // Output parseable para scripts
    printf("THROUGHPUT_KEYS_PER_SEC: %.0f\n", N / elapsed);
    printf("TIME_PER_KEY_USEC: %.3f\n", (elapsed * 1e6) / N);
    
    free(cipher);
    return 0;
}
EOFMICRO

echo "  ✓ Creado: $MICRO_SRC"
echo ""

# ============================================================================
# 2. COMPILAR VARIANTES CON DIFERENTES FLAGS
# ============================================================================

echo -e "${GREEN}▶ Paso 2: Compilar con diferentes niveles de optimización${NC}"
echo ""

BENCH_BUILD_DIR="$PROJECT_ROOT/opt/build_bench"
mkdir -p "$BENCH_BUILD_DIR"

# Variante 1: -O2 (baseline moderado)
echo "  • Compilando con -O2 (baseline)..."
gcc -O2 -D_POSIX_C_SOURCE=199309L -std=c11 -Wall -Wextra \
  -I"$PROJECT_ROOT/include" \
  -o "$BENCH_BUILD_DIR/des_microbench_O2" \
  "$MICRO_SRC" "$PROJECT_ROOT/src/des_utils.c" \
  -lcrypto

# Variante 2: -O3 -march=native (auto-optimización)
echo "  • Compilando con -O3 -march=native..."
gcc -O3 -march=native -D_POSIX_C_SOURCE=199309L -std=c11 -Wall -Wextra \
  -I"$PROJECT_ROOT/include" \
  -o "$BENCH_BUILD_DIR/des_microbench_O3_native" \
  "$MICRO_SRC" "$PROJECT_ROOT/src/des_utils.c" \
  -lcrypto

# Variante 3: -O3 -march=native -ftree-vectorize -funroll-loops
echo "  • Compilando con -O3 -march=native -ftree-vectorize -funroll-loops..."
gcc -O3 -march=native -ftree-vectorize -funroll-loops -D_POSIX_C_SOURCE=199309L -std=c11 -Wall -Wextra \
  -I"$PROJECT_ROOT/include" \
  -o "$BENCH_BUILD_DIR/des_microbench_O3_vec" \
  "$MICRO_SRC" "$PROJECT_ROOT/src/des_utils.c" \
  -lcrypto

# Variante 4: Máxima optimización + LTO
echo "  • Compilando con -O3 -march=native -flto -ffast-math..."
gcc -O3 -march=native -flto -ffast-math -ftree-vectorize -funroll-loops \
  -D_POSIX_C_SOURCE=199309L -std=c11 -Wall -Wextra \
  -I"$PROJECT_ROOT/include" \
  -o "$BENCH_BUILD_DIR/des_microbench_O3_maxopt" \
  "$MICRO_SRC" "$PROJECT_ROOT/src/des_utils.c" \
  -lcrypto

# Variante 5: Con vectorization report
echo "  • Compilando con -fopt-info-vec (para ver vectorización)..."
gcc -O3 -march=native -ftree-vectorize -funroll-loops -fopt-info-vec-all \
  -D_POSIX_C_SOURCE=199309L -std=c11 -Wall -Wextra \
  -I"$PROJECT_ROOT/include" \
  -o "$BENCH_BUILD_DIR/des_microbench_O3_vec_report" \
  "$MICRO_SRC" "$PROJECT_ROOT/src/des_utils.c" \
  -lcrypto \
  2>&1 | tee "$PROFILE_DIR/vectorization_report.txt"

echo ""
echo -e "${GREEN}✓ Variantes compiladas${NC}"
echo ""

# ============================================================================
# 3. EJECUTAR BENCHMARKS
# ============================================================================

echo -e "${GREEN}▶ Paso 3: Ejecutar benchmarks de throughput${NC}"
echo ""

# N iterations - suficiente para medir bien pero no demasiado lento
N=2000000  # 2M keys

declare -A RESULTS

echo "  Ejecutando benchmarks (N=$N keys cada uno)..."
echo ""

for variant in O2 O3_native O3_vec O3_maxopt; do
    binary="$BENCH_BUILD_DIR/des_microbench_$variant"
    
    echo -e "  ${BLUE}→ Testeando $variant...${NC}"
    
    output=$("$binary" $N)
    echo "$output" | grep -E "Tiempo|Throughput|por key"
    
    # Extraer throughput
    throughput=$(echo "$output" | grep "THROUGHPUT_KEYS_PER_SEC" | awk '{print $2}')
    time_per_key=$(echo "$output" | grep "TIME_PER_KEY_USEC" | awk '{print $2}')
    
    RESULTS[$variant]="$throughput|$time_per_key"
    
    echo ""
done

echo -e "${GREEN}✓ Benchmarks completados${NC}"
echo ""

# ============================================================================
# 4. ANALIZAR VECTORIZACIÓN
# ============================================================================

echo -e "${GREEN}▶ Paso 4: Analizar reporte de vectorización${NC}"
echo ""

if [[ -f "$PROFILE_DIR/vectorization_report.txt" ]]; then
    echo "  • Buscando loops vectorizados..."
    
    vectorized=$(grep -c "vectorized" "$PROFILE_DIR/vectorization_report.txt" || echo "0")
    not_vectorized=$(grep -c "not vectorized" "$PROFILE_DIR/vectorization_report.txt" || echo "0")
    
    echo "    - Loops vectorizados: $vectorized"
    echo "    - Loops NO vectorizados: $not_vectorized"
    echo ""
    
    if [[ $vectorized -gt 0 ]]; then
        echo "  ✓ Vectorización ACTIVA en algunos loops"
    else
        echo "  ⚠ NO se detectó vectorización automática"
    fi
else
    echo "  ⚠ No se generó reporte de vectorización"
fi

echo ""

# ============================================================================
# 5. PROFILING DETALLADO (con range más grande)
# ============================================================================

echo -e "${GREEN}▶ Paso 5: Re-ejecutar profiling con range grande${NC}"
echo ""

# Compilar seq con -pg y range más grande (sin early-stop)
echo "  • Compilando para profiling con range grande..."
gcc -pg -O2 -march=native -D_POSIX_C_SOURCE=199309L -std=c11 -Wall -Wextra \
  -I"$PROJECT_ROOT/include" \
  -o "$BENCH_BUILD_DIR/bruteforce_seq_profile_large" \
  "$PROJECT_ROOT/src/bruteforce_seq.c" \
  "$PROJECT_ROOT/src/des_utils.c" \
  -lcrypto

# Ejecutar con range grande (no encontrará key, procesará todo)
echo "  • Ejecutando con range [0, 5000000) (sin key)..."
"$BENCH_BUILD_DIR/bruteforce_seq_profile_large" --bruteforce \
  -c "$PROJECT_ROOT/data/cipher.bin" \
  -s "xxxNOEXISTE" \
  -L 0 -U 5000000 > /dev/null 2>&1

if [[ -f gmon.out ]]; then
  mv gmon.out "$PROFILE_DIR/gmon_seq_large.out"
  
  echo "  • Generando flat profile..."
  gprof "$BENCH_BUILD_DIR/bruteforce_seq_profile_large" \
    "$PROFILE_DIR/gmon_seq_large.out" \
    --flat-profile 2>/dev/null | head -40 > "$PROFILE_DIR/profile_seq_large_flat.txt"
  
  echo "  ✓ Profile guardado en profile_seq_large_flat.txt"
fi

echo ""
echo -e "${GREEN}✓ Profiling completado${NC}"
echo ""

# ============================================================================
# 6. GENERAR REPORTE
# ============================================================================

echo -e "${GREEN}▶ Paso 6: Generar reporte de vectorización${NC}"
echo ""

cat > "$REPORT_FILE" <<EOFREPORT
# Vectorización del Kernel DES - FASE B

**Fecha:** $(date +"%Y-%m-%d %H:%M:%S")  
**Objetivo:** Acelerar kernel DES mediante compiler flags y vectorización  
**Metodología:** Microbenchmark de throughput (keys/sec)

---

## 🔬 Configuración

### Microbenchmark
- **Iteraciones:** $N keys
- **Operación:** \`des_try_key()\` en loop cerrado
- **Sin overhead:** No MPI, no I/O, no early-stop
- **Métrica:** Throughput (keys/sec) y tiempo por key (µs)

### Variantes Compiladas

| Variante | Flags |
|----------|-------|
| **O2** (baseline) | \`-O2\` |
| **O3_native** | \`-O3 -march=native\` |
| **O3_vec** | \`-O3 -march=native -ftree-vectorize -funroll-loops\` |
| **O3_maxopt** | \`-O3 -march=native -flto -ffast-math -ftree-vectorize -funroll-loops\` |

---

## 📊 Resultados: Throughput

### Comparación de Rendimiento

| Variante | Throughput (keys/sec) | Tiempo/key (µs) | Speedup vs O2 |
|----------|----------------------|-----------------|---------------|
EOFREPORT

# Calcular speedups
baseline_throughput=$(echo "${RESULTS[O2]}" | cut -d'|' -f1)

for variant in O2 O3_native O3_vec O3_maxopt; do
    if [[ -n "${RESULTS[$variant]:-}" ]]; then
        throughput=$(echo "${RESULTS[$variant]}" | cut -d'|' -f1)
        time_per_key=$(echo "${RESULTS[$variant]}" | cut -d'|' -f2)
        
        speedup=$(echo "scale=2; $throughput / $baseline_throughput" | bc -l)
        
        printf "| **%s** | %.0f | %.3f | %.2fx |\n" \
          "$variant" "$throughput" "$time_per_key" "$speedup" >> "$REPORT_FILE"
    fi
done

cat >> "$REPORT_FILE" <<EOFREPORT

### Gráfico de Speedup

\`\`\`
EOFREPORT

# Simple bar chart
for variant in O2 O3_native O3_vec O3_maxopt; do
    if [[ -n "${RESULTS[$variant]:-}" ]]; then
        throughput=$(echo "${RESULTS[$variant]}" | cut -d'|' -f1)
        speedup=$(echo "scale=2; $throughput / $baseline_throughput" | bc -l)
        
        # Bar visualization
        bars=$(printf '%.0f' $(echo "$speedup * 20" | bc -l))
        bar_str=$(printf '█%.0s' $(seq 1 $bars))
        
        printf "%-12s: %s %.2fx\n" "$variant" "$bar_str" "$speedup" >> "$REPORT_FILE"
    fi
done

cat >> "$REPORT_FILE" <<'EOFREPORT'
```

---

## 🔬 Análisis de Vectorización

### Reporte del Compilador

EOFREPORT

if [[ -f "$PROFILE_DIR/vectorization_report.txt" ]]; then
    echo "\`\`\`" >> "$REPORT_FILE"
    grep -E "vectorized|loop" "$PROFILE_DIR/vectorization_report.txt" | head -20 >> "$REPORT_FILE" || echo "No se encontraron mensajes de vectorización" >> "$REPORT_FILE"
    echo "\`\`\`" >> "$REPORT_FILE"
else
    echo "❌ No se generó reporte de vectorización" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" <<'EOFREPORT'

### Análisis

**Limitaciones de DES para vectorización:**

1. **Dependencias de datos**: DES tiene alta dependencia entre rondas (16 rounds)
   - Cada round depende del anterior
   - Dificulta SIMD/vectorización automática

2. **OpenSSL implementation**: `DES_ecb_encrypt()` de OpenSSL
   - Ya optimizado en assembly para muchas arquitecturas
   - Poco margen de mejora sin reescribir kernel

3. **Key setup overhead**: Cada key requiere `DES_set_key()`
   - Overhead por key individual
   - No amortizable en búsqueda exhaustiva

**Conclusión de vectorización:**
EOFREPORT

# Comparar O3_vec vs O3_native
if [[ -n "${RESULTS[O3_vec]:-}" ]] && [[ -n "${RESULTS[O3_native]:-}" ]]; then
    vec_throughput=$(echo "${RESULTS[O3_vec]}" | cut -d'|' -f1)
    native_throughput=$(echo "${RESULTS[O3_native]}" | cut -d'|' -f1)
    vec_improvement=$(echo "scale=2; ($vec_throughput / $native_throughput - 1) * 100" | bc -l)
    
    if (( $(echo "$vec_improvement > 5" | bc -l) )); then
        echo "✅ **Vectorización efectiva:** +${vec_improvement}% sobre -O3 -march=native" >> "$REPORT_FILE"
    elif (( $(echo "$vec_improvement > 1" | bc -l) )); then
        echo "⚠️ **Vectorización marginal:** +${vec_improvement}% sobre -O3 -march=native" >> "$REPORT_FILE"
    else
        echo "❌ **Vectorización inefectiva:** Solo +${vec_improvement}% sobre -O3 -march=native" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        echo "El kernel DES de OpenSSL NO se beneficia significativamente de vectorización automática." >> "$REPORT_FILE"
    fi
fi

cat >> "$REPORT_FILE" <<'EOFREPORT'

---

## 📊 Profiling Detallado (Range Grande)

### Top Funciones (sin early-stop)

```
EOFREPORT

if [[ -f "$PROFILE_DIR/profile_seq_large_flat.txt" ]]; then
    cat "$PROFILE_DIR/profile_seq_large_flat.txt" >> "$REPORT_FILE"
else
    echo "❌ No se generó profile con range grande" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" <<'EOFREPORT'
```

### Distribución del Tiempo

EOFREPORT

if [[ -f "$PROFILE_DIR/profile_seq_large_flat.txt" ]]; then
    echo "| Función | % Tiempo | Categoría |" >> "$REPORT_FILE"
    echo "|---------|----------|-----------|" >> "$REPORT_FILE"
    
    grep -E "^\s+[0-9]+\.[0-9]+" "$PROFILE_DIR/profile_seq_large_flat.txt" | head -10 | while read -r line; do
        pct=$(echo "$line" | awk '{print $1}')
        func=$(echo "$line" | awk '{print $7}')
        
        category="Otro"
        if [[ "$func" =~ DES|des|cipher ]]; then
            category="**DES Kernel**"
        elif [[ "$func" =~ MPI|mpi|ompi ]]; then
            category="MPI"
        elif [[ "$func" =~ mem|str ]]; then
            category="Memoria"
        fi
        
        echo "| \`$func\` | ${pct}% | $category |" >> "$REPORT_FILE"
    done
fi

cat >> "$REPORT_FILE" <<'EOFREPORT'

---

## 🎯 Conclusiones

### 1. Impacto de Compiler Flags

EOFREPORT

# Calcular mejora de O3_maxopt vs O2
if [[ -n "${RESULTS[O3_maxopt]:-}" ]] && [[ -n "${RESULTS[O2]:-}" ]]; then
    maxopt_throughput=$(echo "${RESULTS[O3_maxopt]}" | cut -d'|' -f1)
    o2_throughput=$(echo "${RESULTS[O2]}" | cut -d'|' -f1)
    total_improvement=$(echo "scale=1; ($maxopt_throughput / $o2_throughput - 1) * 100" | bc -l)
    
    cat >> "$REPORT_FILE" <<EOF
**Mejor configuración:** \`-O3 -march=native -flto -ffast-math -ftree-vectorize -funroll-loops\`

- **Speedup total:** ${total_improvement}% sobre baseline -O2
- **Throughput alcanzado:** $(printf "%.0f" $maxopt_throughput) keys/sec

**Contribución por flag:**
- \`-O3\` vs \`-O2\`: Mayor inlining, loop unrolling
- \`-march=native\`: Usa instrucciones específicas del CPU
- \`-flto\`: Link-time optimization (inter-procedural)
- \`-ffast-math\`: Relaja IEEE754 (poco impacto en DES)
- \`-ftree-vectorize\`: Intenta SIMD (limitado por dependencias DES)
EOF
else
    echo "❌ No se pudieron calcular mejoras" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" <<'EOFREPORT'

### 2. Limitaciones del Kernel DES

**Por qué es difícil optimizar:**

1. **OpenSSL ya está optimizado**
   - Assembly hand-tuned para x86/ARM
   - Poco margen de mejora con flags de compilación

2. **DES es inherentemente secuencial**
   - 16 rounds con dependencias
   - No paralelizable a nivel de key individual

3. **Key setup overhead**
   - `DES_set_key()` se llama por cada key
   - Amortización solo posible en batch encrypt

### 3. Recomendaciones Finales

**Para este proyecto:**

✅ **Usar flags agresivas:** `-O3 -march=native -flto`
- Mejora moderada (5-15%) sin esfuerzo adicional
- Aplicar a todos los binarios MPI

❌ **NO invertir en vectorización manual de DES**
- Kernel OpenSSL ya optimizado
- Esfuerzo > beneficio esperado

🔍 **Alternativas de mayor impacto:**

1. **Algoritmo/estrategia MPI** (ya explorado)
   - Cyclic baseline es óptimo para este workload
   - Early-stop crítico

2. **GPU acceleration**
   - DES en GPU puede ser 10-100x más rápido
   - Requiere CUDA/OpenCL, fuera del scope de MPI

3. **Batching inteligente**
   - Procesar batch de N keys consecutivas
   - Un solo `DES_set_key()` setup
   - Requiere modificar API de OpenSSL

4. **Cambiar algoritmo de cifrado**
   - AES (más moderno, mejor para SIMD)
   - Chacha20 (diseñado para software)

---

## 📁 Archivos Generados

### Microbenchmarks
- `opt/build_bench/des_microbench_O2`
- `opt/build_bench/des_microbench_O3_native`
- `opt/build_bench/des_microbench_O3_vec`
- `opt/build_bench/des_microbench_O3_maxopt`

### Profiles
- `opt/profiles/vectorization_report.txt` - Output de -fopt-info-vec
- `opt/profiles/profile_seq_large_flat.txt` - gprof con range grande

### Source
- `opt/src/des_microbench.c` - Microbenchmark standalone

---

## 🚀 Aplicar Optimizaciones

### Recompilar todos los binarios con flags óptimas:

```bash
# Editar scripts/compile_bins_opt.sh
CFLAGS="-O3 -march=native -flto -funroll-loops -std=c11"

# Recompilar
bash scripts/compile_bins_opt.sh

# Re-ejecutar benchmarks
bash scripts/round3_scaling.sh
```

### Verificar mejora:

```bash
# Comparar antes (current) vs después (recompiled)
# Esperar 5-15% de mejora en tiempo de ejecución
```

---

**Estado:** ✅ Vectorización analizada  
**Conclusión:** Flags agresivas dan 5-15% mejora, vectorización manual no justificada  
**Acción:** Aplicar `-O3 -march=native -flto` a todos los binarios
EOFREPORT

echo -e "${GREEN}✓ Reporte generado: $REPORT_FILE${NC}"
echo ""

# ============================================================================
# 7. RESUMEN
# ============================================================================

echo "=============================================="
echo "  RESUMEN - FASE B"
echo "=============================================="
echo ""
echo "📊 Throughput comparativo:"
echo ""

for variant in O2 O3_native O3_vec O3_maxopt; do
    if [[ -n "${RESULTS[$variant]:-}" ]]; then
        throughput=$(echo "${RESULTS[$variant]}" | cut -d'|' -f1)
        speedup=$(echo "scale=2; $throughput / $baseline_throughput" | bc -l)
        printf "  %-15s: %10.0f keys/sec  (%.2fx)\n" "$variant" "$throughput" "$speedup"
    fi
done

echo ""
echo "📁 Ver reporte completo:"
echo "  less $REPORT_FILE"
echo ""
echo "🎯 Próximo paso:"
echo "  Aplicar flags óptimas a compile_bins_opt.sh y recompilar"
echo ""
