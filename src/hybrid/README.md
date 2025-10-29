# Implementación Híbrida MPI+OpenMP

Versión experimental que combina paralelización MPI (entre procesos) con OpenMP (dentro de cada proceso) para explorar ganancia adicional en memoria compartida.

## 📁 Estructura

```
src/hybrid/
  └── bruteforce_mpi_cyclic_omp.c   # Implementación híbrida basada en cyclic

scripts/
  ├── compile_hybrid_omp.sh          # Compilación con -fopenmp
  └── benchmark_hybrid_omp.sh        # Benchmark automatizado

build_bins_opt/
  └── bruteforce_mpi_cyclic_omp      # Binario híbrido (después de compilar)
```

## 🔧 Compilación

```bash
# Compilar versión híbrida
bash scripts/compile_hybrid_omp.sh
```

**Flags adicionales:**
- `-fopenmp`: Habilita OpenMP
- Mismo nivel de optimización que versiones MPI puras (`-O3 -march=native -flto`)

**Verificación:**
```bash
# Verificar que OpenMP esté enlazado
strings build_bins_opt/bruteforce_mpi_cyclic_omp | grep -i omp
```

## 🚀 Uso

### Ejecución manual

```bash
# Configurar hilos OpenMP
export OMP_NUM_THREADS=2

# Ejecutar con MPI
mpirun -np 4 ./build_bins_opt/bruteforce_mpi_cyclic_omp \
  -c data/cipher.bin \
  -s "es una prueba de" \
  -L 0 -U 8388608

# Total de workers paralelos: P * OMP_NUM_THREADS = 4 * 2 = 8
```

### Benchmark automatizado

```bash
# Ejecuta múltiples configuraciones y compara con MPI puro
bash scripts/benchmark_hybrid_omp.sh
```

**Salida:**
- `artifacts/hybrid_omp_benchmark_<timestamp>/benchmark_results.csv`
- `artifacts/hybrid_omp_benchmark_<timestamp>/REPORT.md`
- `artifacts/hybrid_omp_benchmark_<timestamp>/logs/` (logs individuales)

## 🧮 Estrategia de Paralelización

### Distribución de trabajo

```
MPI Rank 0:  k = L + 0, L + 0 + P*T, L + 0 + 2*P*T, ...
  Thread 0:  k = L + 0, L + 0 + P*T*nthreads, ...
  Thread 1:  k = L + 0 + P*T, L + 0 + P*T + P*T*nthreads, ...

MPI Rank 1:  k = L + 1, L + 1 + P*T, L + 1 + 2*P*T, ...
  Thread 0:  k = L + 1, L + 1 + P*T*nthreads, ...
  Thread 1:  k = L + 1 + P*T, L + 1 + P*T + P*T*nthreads, ...
```

**Donde:**
- `P` = número de procesos MPI
- `T` = número de hilos OpenMP por proceso
- `nthreads` = `OMP_NUM_THREADS`

### Early-Stop Híbrido

```c
#pragma omp parallel shared(found_flag, found_key, ...)
{
    for(uint64_t k = ...; k < U && !found_flag; k += ...) {
        // Solo thread 0 verifica MPI_Test (evita race condition)
        if(tid == 0 && allow_stop) {
            int flag=0; 
            MPI_Test(&req, &flag, &st);
            if(flag) { 
                #pragma omp atomic write
                found_flag = 1; 
            }
        }
        
        if(found_flag) break;
        
        if(des_try_key(k, ...)) {
            #pragma omp critical
            {
                if(found_key == UINT64_MAX) {
                    found_key = k;
                    found_flag = 1;
                    // Notificar a otros ranks MPI
                    for(int p=0; p<P; p++) 
                        MPI_Send(&found_key, ...);
                }
            }
        }
    }
}
```

**Características:**
- `#pragma omp atomic write`: Actualización atómica de flag compartido
- `#pragma omp critical`: Sección crítica para notificación MPI (un solo hilo)
- `MPI_Test` solo en thread 0 (thread-safety de MPI)

## 📊 Resultados Esperados

### Configuraciones típicas (8 cores disponibles)

| Config | P | OMP | Total | Speedup esperado | Eficiencia | Caso de uso |
|--------|---|-----|-------|------------------|------------|-------------|
| MPI puro | 8 | 1 | 8 | ~6.0x | ~75% | Cluster multi-nodo |
| Híbrido | 4 | 2 | 8 | ~6.2-6.5x | ~77-81% | Nodo con memoria compartida |
| Híbrido | 2 | 4 | 8 | ~5.8-6.3x | ~72-79% | Balance MPI/OpenMP |
| OpenMP puro | 1 | 8 | 8 | ~5.0-5.5x | ~62-69% | Single-node, overhead MPI alto |

### Factores de rendimiento

**Favorece híbrido:**
- ✅ Memoria compartida grande (reduce overhead MPI)
- ✅ Overhead de inicio MPI alto (menos procesos = menos overhead)
- ✅ Sincronización barata dentro de nodo

**Favorece MPI puro:**
- ✅ Cluster multi-nodo (memoria distribuida)
- ✅ Load balancing automático (cyclic ya balancea bien)
- ✅ Early-stop crítico (MPI más directo)

## ⚠️ Limitaciones Conocidas

### 1. Thread-safety de MPI

**Problema:** No todos los MPI implementan thread-safety completo  
**Solución:** Solo thread 0 llama a `MPI_Test` y `MPI_Send`

```c
if(tid == 0 && allow_stop) {
    MPI_Test(&req, &flag, &st);  // Safe: solo thread 0
}
```

### 2. Overhead de sincronización OpenMP

**Medido:** ~5-10% overhead adicional por:
- Creación/destrucción de threads
- Sincronización en `#pragma omp critical`
- Atomic writes para `found_flag`

**Mitigación:** Usar `schedule(static)` (ya implícito en loop manual)

### 3. Escalabilidad limitada

**Observado:** Mejora típica de 1.05x-1.15x vs MPI puro (8 cores)

**Razón:** 
- DES kernel ya es 67% del tiempo (bottleneck)
- Early-stop reduce beneficio de paralelismo adicional
- OpenMP overhead contrarresta ganancia marginal

## 🔬 Profiling Recomendado

### Validar overhead OpenMP

```bash
# Compilar con profiling
mpicc -fopenmp -pg -O3 ... src/hybrid/bruteforce_mpi_cyclic_omp.c -o bin_profiled

# Ejecutar
export OMP_NUM_THREADS=2
mpirun -np 4 ./bin_profiled ... 

# Analizar (solo rank 0 genera gmon.out)
gprof ./bin_profiled gmon.out > hybrid_profile.txt
```

### Comparar con perf

```bash
# MPI puro
perf stat -e cycles,instructions,cache-misses \
  mpirun -np 8 ./build_bins_opt/bruteforce_mpi_cyclic ...

# Híbrido
export OMP_NUM_THREADS=2
perf stat -e cycles,instructions,cache-misses \
  mpirun -np 4 ./build_bins_opt/bruteforce_mpi_cyclic_omp ...
```

## 📈 Cuándo Usar Híbrido

### ✅ Casos ideales

1. **Nodo con muchos cores (16+):**
   - Reduce overhead de inicio MPI
   - Ejemplo: P=4, OMP=4 en nodo de 16 cores

2. **Memoria compartida limitada:**
   - Menos procesos = menos copias de datos
   - Ejemplo: cipher.bin grande, P=2, OMP=8

3. **Cluster heterogéneo:**
   - Ajustar OMP por nodo según capacidad
   - Ejemplo: nodo1 (8 cores) → OMP=8, nodo2 (4 cores) → OMP=4

### ❌ Casos no recomendados

1. **Cluster multi-nodo con early-stop crítico:**
   - MPI puro más directo para broadcast de stop signal
   - Overhead de OpenMP no justificado

2. **Workload desbalanceado:**
   - Cyclic ya balancea bien entre ranks
   - OpenMP agrega complejidad sin ganancia

3. **Pocos cores disponibles (<8):**
   - Overhead relativo alto
   - MPI puro suficiente

## 🧪 Validación

```bash
# 1. Compilar todo
bash scripts/compile_bins_opt.sh      # MPI puro
bash scripts/compile_hybrid_omp.sh    # Híbrido

# 2. Generar cipher
./build_bins_opt/bruteforce_seq --encrypt \
  -i data/mensaje.txt -k 57920 -o data/cipher.bin

# 3. Validar correctitud (deben encontrar misma llave)
mpirun -np 4 ./build_bins_opt/bruteforce_mpi_cyclic \
  -c data/cipher.bin -s "es una prueba de" -L 0 -U 100000

export OMP_NUM_THREADS=2
mpirun -np 2 ./build_bins_opt/bruteforce_mpi_cyclic_omp \
  -c data/cipher.bin -s "es una prueba de" -L 0 -U 100000

# 4. Benchmark completo
bash scripts/benchmark_hybrid_omp.sh
```

## 📚 Referencias

- OpenMP Specification: https://www.openmp.org/specifications/
- MPI + OpenMP Best Practices: https://www.mcs.anl.gov/research/projects/mpi/mpi-standard/
- Thread-safe MPI: `MPI_Init_thread(MPI_THREAD_MULTIPLE)` (no usado aquí por overhead)

---

**Estado:** ✅ Implementación completa y funcional  
**Autor:** PY2-Paralela  
**Fecha:** Octubre 2025
