#!/usr/bin/env bash
# ============================================================================
# profile_des_kernel.sh - Profiling del kernel DES
# ============================================================================
# Objetivo: Identificar cuello de botella real en DES_ecb_encrypt
# Herramientas: gprof (funciona 100% en WSL), perf (si disponible)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROFILE_DIR="$PROJECT_ROOT/opt/profiles"
REPORT_FILE="$PROJECT_ROOT/opt/reports/PROFILE_DES.md"

cd "$PROJECT_ROOT"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=============================================="
echo "  FASE A: Profiling del Kernel DES"
echo "=============================================="
echo ""

mkdir -p "$PROFILE_DIR"
mkdir -p "$(dirname "$REPORT_FILE")"

# ============================================================================
# 1. COMPILAR CON PROFILING FLAGS
# ============================================================================

echo -e "${GREEN}▶ Paso 1: Compilar con -pg (gprof)${NC}"
echo ""

PROF_BUILD_DIR="$PROJECT_ROOT/opt/build_profiled"
mkdir -p "$PROF_BUILD_DIR"

# Compilar baseline cyclic con profiling
echo "  • Compilando bruteforce_mpi con -pg..."
mpicc -pg -O2 -march=native -std=c11 -Wall -Wextra \
  -I"$PROJECT_ROOT/include" \
  -o "$PROF_BUILD_DIR/bruteforce_mpi_profiled" \
  "$PROJECT_ROOT/src/bruteforce_mpi.c" \
  "$PROJECT_ROOT/src/des_utils.c" \
  -lcrypto

echo "  • Compilando bruteforce_mpi_cyclic con -pg..."
mpicc -pg -O2 -march=native -std=c11 -Wall -Wextra \
  -I"$PROJECT_ROOT/include" \
  -o "$PROF_BUILD_DIR/bruteforce_mpi_cyclic_profiled" \
  "$PROJECT_ROOT/src/bruteforce_mpi_cyclic.c" \
  "$PROJECT_ROOT/src/des_utils.c" \
  -lcrypto

# Compilar secuencial (para comparar sin overhead MPI)
echo "  • Compilando bruteforce_seq con -pg..."
gcc -pg -O2 -march=native -std=c11 -Wall -Wextra \
  -I"$PROJECT_ROOT/include" \
  -o "$PROF_BUILD_DIR/bruteforce_seq_profiled" \
  "$PROJECT_ROOT/src/bruteforce_seq.c" \
  "$PROJECT_ROOT/src/des_utils.c" \
  -lcrypto

echo ""
echo -e "${GREEN}✓ Binarios profiled compilados${NC}"
echo ""

# ============================================================================
# 2. EJECUTAR BENCHMARKS CORTOS
# ============================================================================

echo -e "${GREEN}▶ Paso 2: Ejecutar benchmarks con profiling${NC}"
echo ""

CIPHER="$PROJECT_ROOT/data/cipher.bin"
SUBSTR="es una prueba de"
L=0
U=1000000  # 1M keys para profile significativo
P=4

# Test 1: Secuencial (sin MPI overhead)
echo "  • Test 1: Secuencial (range [0, 1000000))..."
cd "$PROJECT_ROOT"
"$PROF_BUILD_DIR/bruteforce_seq_profiled" --bruteforce \
  -c "$CIPHER" -s "$SUBSTR" -L $L -U $U > /dev/null 2>&1 || true

if [[ -f gmon.out ]]; then
  mv gmon.out "$PROFILE_DIR/gmon_seq.out"
  echo "    → gmon.out guardado"
fi

# Test 2: MPI baseline
echo "  • Test 2: MPI baseline cyclic (P=4)..."
mpirun --oversubscribe -np $P "$PROF_BUILD_DIR/bruteforce_mpi_profiled" \
  -c "$CIPHER" -s "$SUBSTR" -L $L -U $U > /dev/null 2>&1 || true

# Mover gmon.out de cada rank
for rank in $(seq 0 $((P-1))); do
  if [[ -f "gmon.out.$rank" ]]; then
    mv "gmon.out.$rank" "$PROFILE_DIR/gmon_mpi_rank${rank}.out"
    echo "    → gmon rank $rank guardado"
  fi
done

# Test 3: MPI cyclic optimized
echo "  • Test 3: MPI cyclic optimized (P=4)..."
mpirun --oversubscribe -np $P "$PROF_BUILD_DIR/bruteforce_mpi_cyclic_profiled" \
  -c "$CIPHER" -s "$SUBSTR" -L $L -U $U > /dev/null 2>&1 || true

for rank in $(seq 0 $((P-1))); do
  if [[ -f "gmon.out.$rank" ]]; then
    mv "gmon.out.$rank" "$PROFILE_DIR/gmon_cyclic_rank${rank}.out"
  fi
done

echo ""
echo -e "${GREEN}✓ Benchmarks completados${NC}"
echo ""

# ============================================================================
# 3. ANALIZAR CON GPROF
# ============================================================================

echo -e "${GREEN}▶ Paso 3: Analizar con gprof${NC}"
echo ""

# Secuencial
if [[ -f "$PROFILE_DIR/gmon_seq.out" ]]; then
  echo "  • Analizando secuencial..."
  gprof "$PROF_BUILD_DIR/bruteforce_seq_profiled" "$PROFILE_DIR/gmon_seq.out" \
    > "$PROFILE_DIR/profile_seq_full.txt" 2>/dev/null
  
  # Extraer flat profile (top functions)
  gprof "$PROF_BUILD_DIR/bruteforce_seq_profiled" "$PROFILE_DIR/gmon_seq.out" \
    --flat-profile 2>/dev/null | head -30 > "$PROFILE_DIR/profile_seq_flat.txt"
fi

# MPI ranks (analizar rank 0 como representativo)
if [[ -f "$PROFILE_DIR/gmon_mpi_rank0.out" ]]; then
  echo "  • Analizando MPI rank 0..."
  gprof "$PROF_BUILD_DIR/bruteforce_mpi_profiled" "$PROFILE_DIR/gmon_mpi_rank0.out" \
    > "$PROFILE_DIR/profile_mpi_rank0_full.txt" 2>/dev/null
  
  gprof "$PROF_BUILD_DIR/bruteforce_mpi_profiled" "$PROFILE_DIR/gmon_mpi_rank0.out" \
    --flat-profile 2>/dev/null | head -30 > "$PROFILE_DIR/profile_mpi_rank0_flat.txt"
fi

echo ""
echo -e "${GREEN}✓ Análisis gprof completado${NC}"
echo ""

# ============================================================================
# 4. INTENTAR PERF (si disponible)
# ============================================================================

echo -e "${GREEN}▶ Paso 4: Intentar perf (puede fallar en WSL)${NC}"
echo ""

if command -v perf &>/dev/null; then
  echo "  • perf detectado, intentando..."
  
  # perf stat (contadores básicos)
  echo "  • perf stat del secuencial..."
  perf stat -e cycles,instructions,cache-references,cache-misses,branches,branch-misses \
    "$PROF_BUILD_DIR/bruteforce_seq_profiled" --bruteforce \
    -c "$CIPHER" -s "$SUBSTR" -L $L -U $U \
    2>&1 | tee "$PROFILE_DIR/perf_stat_seq.txt" || echo "    ⚠ perf stat falló"
  
  # perf record (puede fallar por permisos en WSL)
  echo "  • perf record del secuencial (puede requerir sudo)..."
  perf record -g -o "$PROFILE_DIR/perf_seq.data" \
    "$PROF_BUILD_DIR/bruteforce_seq_profiled" --bruteforce \
    -c "$CIPHER" -s "$SUBSTR" -L $L -U $U \
    > /dev/null 2>&1 || echo "    ⚠ perf record falló (normal en WSL)"
  
  if [[ -f "$PROFILE_DIR/perf_seq.data" ]]; then
    perf report -i "$PROFILE_DIR/perf_seq.data" --stdio \
      > "$PROFILE_DIR/perf_report_seq.txt" 2>/dev/null || true
  fi
else
  echo -e "  ${YELLOW}⚠ perf no disponible en este sistema${NC}"
fi

echo ""

# ============================================================================
# 5. GENERAR REPORTE
# ============================================================================

echo -e "${GREEN}▶ Paso 5: Generar reporte de análisis${NC}"
echo ""

cat > "$REPORT_FILE" <<'EOFMD'
# Profiling del Kernel DES - Análisis de Cuello de Botella

**Fecha:** $(date +"%Y-%m-%d %H:%M:%S")  
**Objetivo:** Identificar si el cuello de botella está en `DES_ecb_encrypt` o en el loop de prueba de llaves  
**Herramientas:** gprof, perf (si disponible en WSL)

---

## 🔬 Metodología

### Configuración del Test
- **Rango:** [0, 1,000,000) keys
- **Cipher:** data/cipher.bin
- **Substring:** "es una prueba de"
- **Compilación:** `-pg -O2 -march=native`
- **Variantes testeadas:**
  1. Secuencial (sin MPI overhead)
  2. MPI baseline (naive)
  3. MPI cyclic optimized

---

## 📊 Resultados: Secuencial (sin overhead MPI)

### Top 10 Funciones (gprof flat profile)

```
EOFMD

# Insertar resultados de gprof seq
if [[ -f "$PROFILE_DIR/profile_seq_flat.txt" ]]; then
  cat "$PROFILE_DIR/profile_seq_flat.txt" >> "$REPORT_FILE"
else
  echo "❌ No se generó profile_seq_flat.txt" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" <<'EOFMD'
```

### Análisis de Porcentajes

EOFMD

# Extraer porcentajes automáticamente
if [[ -f "$PROFILE_DIR/profile_seq_flat.txt" ]]; then
  echo "| Función | % Tiempo | Descripción |" >> "$REPORT_FILE"
  echo "|---------|----------|-------------|" >> "$REPORT_FILE"
  
  # Parsear top 5 funciones
  grep -E "^\s+[0-9]+\.[0-9]+" "$PROFILE_DIR/profile_seq_flat.txt" | head -5 | while read -r line; do
    pct=$(echo "$line" | awk '{print $1}')
    func=$(echo "$line" | awk '{print $7}')
    
    desc=""
    case "$func" in
      *DES*|*des*) desc="Criptografía DES (OpenSSL)" ;;
      *try_key*|*des_try_key*) desc="Loop de prueba de llaves" ;;
      *decrypt*) desc="Decriptación DES" ;;
      *memmove*|*memcpy*|*memcmp*) desc="Operaciones de memoria" ;;
      *MPI*|*mpi*) desc="Comunicación MPI" ;;
      *) desc="Auxiliar" ;;
    esac
    
    echo "| \`$func\` | $pct% | $desc |" >> "$REPORT_FILE"
  done
else
  echo "❌ No hay datos de profiling" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" <<'EOFMD'

---

## 📊 Resultados: MPI Baseline (rank 0)

### Top 10 Funciones

```
EOFMD

if [[ -f "$PROFILE_DIR/profile_mpi_rank0_flat.txt" ]]; then
  cat "$PROFILE_DIR/profile_mpi_rank0_flat.txt" >> "$REPORT_FILE"
else
  echo "❌ No se generó profile_mpi_rank0_flat.txt" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" <<'EOFMD'
```

---

## 🎯 Conclusiones

### 1. Identificación del Cuello de Botella

EOFMD

# Calcular conclusión automática basado en porcentajes
if [[ -f "$PROFILE_DIR/profile_seq_flat.txt" ]]; then
  DES_PCT=$(grep -i "des" "$PROFILE_DIR/profile_seq_flat.txt" | head -1 | awk '{print $1}' || echo "0")
  MPI_PCT=$(grep -i "mpi\|ompi\|pmpi" "$PROFILE_DIR/profile_seq_flat.txt" | head -1 | awk '{print $1}' || echo "0")
  
  DES_NUM=$(echo "$DES_PCT" | sed 's/[^0-9.]//g')
  MPI_NUM=$(echo "$MPI_PCT" | sed 's/[^0-9.]//g')
  
  if (( $(echo "$DES_NUM > 80" | bc -l 2>/dev/null || echo 0) )); then
    cat >> "$REPORT_FILE" <<EOF
**✅ CONFIRMADO: Cuello de botella es CPU-bound (DES computation)**

- **DES_ecb_encrypt y funciones relacionadas:** ~${DES_PCT}% del tiempo
- **MPI overhead:** ~${MPI_PCT}% del tiempo
- **Conclusión:** El 80%+ del tiempo está en criptografía DES

**Implicaciones:**
- ✅ Las optimizaciones MPI tienen impacto limitado (<20%)
- ✅ El foco debe estar en optimizar el kernel DES
- ✅ Vectorización / SIMD tiene mayor potencial
- ⚠️  Chunking sacrifica early-stop sin ganar en compute
EOF
  elif (( $(echo "$MPI_NUM > 20" | bc -l 2>/dev/null || echo 0) )); then
    cat >> "$REPORT_FILE" <<EOF
**⚠️  MIXTO: Tiempo dividido entre DES y MPI**

- **DES computation:** ~${DES_PCT}%
- **MPI overhead:** ~${MPI_PCT}%
- **Conclusión:** Ambos componentes son significativos

**Implicaciones:**
- ⚡ Optimizar DES kernel (mayor impacto)
- ⚡ Reducir frecuencia de MPI checks (impacto moderado)
- 🔍 Considerar batching inteligente
EOF
  else
    cat >> "$REPORT_FILE" <<EOF
**📊 ANÁLISIS MANUAL REQUERIDO**

Los porcentajes obtenidos requieren revisión manual del flat profile.
Ver archivos en \`opt/profiles/\` para análisis detallado.
EOF
  fi
else
  cat >> "$REPORT_FILE" <<EOF
**❌ NO SE PUDO GENERAR ANÁLISIS AUTOMÁTICO**

Ver archivos de profiling en \`opt/profiles/\` para análisis manual.
EOF
fi

cat >> "$REPORT_FILE" <<'EOFMD'

### 2. Recomendaciones de Optimización

Basado en el análisis de profiling:

#### **Prioridad ALTA** (si DES > 80%)
1. **Vectorización del kernel DES**
   - Flags: `-O3 -march=native -ftree-vectorize -funroll-loops`
   - Verificar con: `gcc -fopt-info-vec`
   - Potencial: 2-4x speedup si vectoriza bien

2. **DES lookup tables caching**
   - Precalcular S-boxes en memoria local
   - Reducir cache misses

3. **Batch DES operations**
   - Procesar múltiples keys antes de checkear match
   - Amortizar overhead de setup

#### **Prioridad MEDIA** (siempre aplicable)
1. **Compiler optimizations agresivas**
   - `-O3 -march=native -flto -ffast-math`
   - Profile-guided optimization (PGO)

2. **Memory prefetching**
   - `__builtin_prefetch()` para cipher data
   - Prefetch próximas keys

#### **Prioridad BAJA** (si MPI > 20%)
1. **Reducir frecuencia de MPI checks**
   - Solo si no sacrifica early-stop
   - Backoff exponencial

2. **Batching de comunicación**
   - Ya explorado en adaptive_opt
   - Limitado por early-stop requirement

---

## 📁 Archivos Generados

### Profiles completos
- `opt/profiles/profile_seq_full.txt` - Secuencial completo
- `opt/profiles/profile_mpi_rank0_full.txt` - MPI rank 0 completo

### Flat profiles (top functions)
- `opt/profiles/profile_seq_flat.txt` - Top funciones secuencial
- `opt/profiles/profile_mpi_rank0_flat.txt` - Top funciones MPI

### Perf (si disponible)
- `opt/profiles/perf_stat_seq.txt` - Contadores hardware
- `opt/profiles/perf_report_seq.txt` - Call graph (si generado)

---

## 🚀 Próximo Paso: FASE B - Vectorización

Ver `opt/scripts/vectorize_des_test.sh` para:
1. Compilar con flags de vectorización
2. Crear microbenchmark de throughput
3. Validar vectorización efectiva
4. Medir speedup real

**Comando:**
```bash
bash opt/scripts/vectorize_des_test.sh
```

---

**Estado:** ✅ Profiling completado  
**Siguiente:** Vectorización del kernel DES (FASE B)
EOFMD

echo -e "${GREEN}✓ Reporte generado: $REPORT_FILE${NC}"
echo ""

# ============================================================================
# 6. RESUMEN
# ============================================================================

echo "=============================================="
echo "  RESUMEN"
echo "=============================================="
echo ""
echo "📁 Archivos generados:"
echo "  • $PROFILE_DIR/profile_seq_flat.txt"
echo "  • $PROFILE_DIR/profile_mpi_rank0_flat.txt"
echo "  • $REPORT_FILE"
echo ""
echo "📊 Ver reporte completo:"
echo "  less $REPORT_FILE"
echo ""
echo "🚀 Próximo paso:"
echo "  bash opt/scripts/vectorize_des_test.sh"
echo ""
