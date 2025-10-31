PY2-Paralela — Brute-force DES (MPI)
------------------------------------

Romper DES por fuerza bruta. Incluye una versión secuencial y cinco enfoques paralelos con MPI: naïve (bloques), cíclico, dinámico, dinámico-adaptativo y permutado. Se mide tiempo secuencial, tiempo paralelo (tₚ = max rank) y speedup = tₛ / tₚ. Usa OpenSSL (libcrypto) para DES.

**Estado:** ✅ Proyecto completo con profiling, optimización y validación  
**Ganador:** `bruteforce_mpi_cyclic` (3.57x @ P=4, 89% eficiencia)  
**Mejora validada:** +2.1% con compiler flags optimizadas

---

## 📊 Resultados del Pipeline Evolutivo

### Pipeline de 4 Rounds
- **Round 0:** 6 algoritmos explorados → 3 finalistas
- **Round 1A:** Comparación algorítmica → cyclic, adaptive, permuted pasan
- **Round 1B:** Tuning de hiperparámetros → cyclic mantiene liderazgo
- **Round 2:** Competencia final → **cyclic ganador (3.0x promedio)**
- **Round 3:** Scaling analysis → 3.57x @ P=4 (89% eff), límite en P=8

### Profiling y Optimización
- **FASE A (gprof):** DES kernel = 67%, MPI overhead < 1%
- **FASE B (vectorización):** Compiler flags → +2.1% mejora validada
- **Optimizaciones MPI:** Chunking/batching fallaron (-6x a -8x slowdown)

**📚 Documentación completa:** Ver [`opt/reports/FINAL_REPORT.md`](opt/reports/FINAL_REPORT.md)

---

Qué hace
-----------

*   Cifra un texto de prueba con una “llave” (entero) para generar un cipher.bin.
*   Busca la llave probando candidatas en un rango \[L,U).
*   Descifra el buffer en memoria con cada candidata.
*   Verifica si el texto claro contiene la subcadena objetivo.
*   Difunde _early-stop_ al encontrar la llave.
    

Estrategias de paralelización
-------------------------------------------
## 

| Binario | Estrategia de paralelización | Qué se paraleliza (unidad de trabajo) | Dónde y cómo en el código | Idea breve |
| --- | --- | --- | --- | --- |
| `bin/bruteforce_seq` | Secuencial | **Recorrido completo de llaves** `k ∈ [L, U)` en un solo proceso. | Bucle único que hace: generar llave candidata → `des_decrypt_buffer(cipher, …, k)` → comprobar subcadena → si coincide, termina. | Recorre todo el rango en un solo proceso. |
| `bin/bruteforce_mpi` | Naïve (bloques contiguos) | **Partición estática por bloques:** cada rank recibe un subrango contiguo distinto de llaves. | Antes del bucle, cada proceso calcula su `[Lᵣ, Uᵣ)`; dentro del bucle llama localmente a `des_decrypt_buffer` y verifica la subcadena. Al encontrar, **difunde señal de parada** (broadcast/reducción) y todos salen. | Divide `[L,U)` en P bloques, 1 por proceso. Overhead mínimo; varianza alta por “suerte” del primer acierto. |
| `bin/bruteforce_mpi_cyclic` | Cíclico (round-robin por índice) | **Interleaving de llaves:** cada rank prueba `k = L + rank`, y luego `k += P`. | El bucle usa un **stride = P**; cada iteración descifra y compara. Early-stop global con señal de parada. | Mezcla la posición de la llave entre procesos y reduce el sesgo de “quién empieza antes”. |
| `bin/bruteforce_mpi_dynamic` | Dinámico (master–worker, `-B`) | **Asignación dinámica de chunks:** el maestro entrega **bloques de B llaves** al worker que queda libre. | Rank 0 mantiene un puntero global y **despacha rangos** `[start, start+B)` vía `MPI_Send/MPI_Recv`. Workers procesan el subrango (bucle local con `des_decrypt_buffer`) y piden más. Si alguien encuentra, el maestro **ordena parar**. | Balancea carga y heterogeneidad: todos trabajan casi siempre. |
| `bin/bruteforce_mpi_dynamic_adaptive` | Dinámico-adaptativo (master–worker, `-T`) | **Chunks de tamaño variable:** el maestro ajusta B para que cada asignación dure ≈ `T` ms. | Igual que el dinámico, pero el maestro **estima throughput** con tiempos recientes por worker y recalcula el tamaño del siguiente chunk para acercarse a `T`. Early-stop coordinado por el maestro. | Mantiene el balance aun con ruido; reduce varianza de tiempos. |
| `bin/bruteforce_mpi_permuted` | Permutado por stride/LCG (`-R`) | **Orden barajado de llaves**: cada rank recorre un **stride** pero aplicando una **permutación lineal (LCG)** con semilla `R` sobre el índice. | El bucle no visita `k` en orden natural; usa `k’ = (a·k + b) mod U` (parámetros derivados de `R`) y stride entre ranks. Cada iteración descifra y compara; early-stop global cuando alguien acierta. | “Baraja” el espacio para evitar sesgos espaciales sin maestro ni colas. |

**Parámetros comunes:**

*   \-c : ruta del cipher.bin
*   \-s "": subcadena a buscar en el texto claro
*   \-L \-U : rango de llaves \[L,U)
    

**Parámetros por variante:**

*   Dinámico: -B
*   Dinámico-adaptativo: -T
*   Permutado: -R

## Requisitos

-   OpenMPI (`mpicc`, `mpirun`)
-   OpenSSL (`libcrypto`)
-   GCC/Clang (C11)

## Compilación

```bash
# Binarios baseline
make

# Binarios con compiler flags optimizadas (+2.1% validado)
bash scripts/compile_bins_opt.sh
```

**Binarios optimizados disponibles en:** `build_bins_opt/`

---

## 🔬 Reproducir Pipeline y Profiling

### Validar Estado del Proyecto
```bash
bash scripts/validate_reproducibility.sh
```

### Reproducir Pipeline Completo (4 Rounds)
```bash
bash scripts/round0_probe.sh          # Exploración inicial
bash scripts/round1a_algorithmic.sh   # Comparación algorítmica
bash scripts/round1b_tuning.sh        # Tuning de hiperparámetros
bash scripts/round2_final.sh          # Competencia final
bash scripts/round3_scaling.sh        # Análisis de scaling
```

### Reproducir Profiling (FASE A + B)
```bash
bash opt/scripts/profile_des_kernel.sh    # FASE A: Identificar bottleneck
bash opt/scripts/vectorize_des_test.sh    # FASE B: Vectorización y flags
```

### Validar Mejora con Compiler Flags
```bash
bash scripts/benchmark_flags_long.sh      # Benchmark estable (5M keys)
```

**Tiempo total:** ~30 minutos (automatizado)

---


## Ejemplos de uso

Consulta el archivo [**comandos.txt**](./comandos.txt) para cualquier duda.  
Ahí se detallan **todas las líneas de comando disponibles** y **su propósito** dentro del proyecto.

### Secuencial y encriptar
```bash
./bin/bruteforce_seq --encrypt -i data/mensaje.txt -k 57920 -o data/cipher.bin
./bin/bruteforce_seq --bruteforce -c data/cipher.bin -s "es una prueba de" -L 0 -U 16777216
```
### Paralelo (4 procesos de ejemplo)
```bash
mpirun -np 4 ./bin/bruteforce_mpi                     -c data/cipher.bin -s "es una prueba de" -L 0 -U 16777216
mpirun -np 4 ./bin/bruteforce_mpi_cyclic              -c data/cipher.bin -s "es una prueba de" -L 0 -U 16777216
mpirun -np 4 ./bin/bruteforce_mpi_dynamic             -c data/cipher.bin -s "es una prueba de" -L 0 -U 16777216 -B 50000
mpirun -np 4 ./bin/bruteforce_mpi_dynamic_adaptive   -c data/cipher.bin -s "es una prueba de" -L 0 -U 16777216 -T 30
mpirun -np 4 ./bin/bruteforce_mpi_permuted            -c data/cipher.bin -s "es una prueba de" -L 0 -U 16777216 -R 12345
```

### Salida típica ejemplo
**Detalle por proceso**

## 

RANK | TESTS | STATUS        | TIME(s)

\-----+-------+---------------+--------

  0  | 28672 | STOP(SIGNAL)  | 0.0221

  3  | 26891 | FOUND         | 0.0209  <==
  
**Resultado:** ✔ Llave encontrada
-   Rank : 3
-   Llave: 57920
-   Tiempo total (max rank): 0.022228 s



---

## 📚 Documentación Completa

### Reportes Principales
- **[`opt/reports/FINAL_REPORT.md`](opt/reports/FINAL_REPORT.md)** - 🎯 Reporte final completo (542 líneas)
  - Pipeline evolutivo (4 rounds)
  - Profiling FASE A + B
  - Validación de mejoras (+2.1%)
  - Conclusiones y reproducibilidad

### Índice de Documentación
- **[`opt/INDEX.md`](opt/INDEX.md)** - Índice completo de todos los reportes
- **[`opt/LESSONS_LEARNED.md`](opt/LESSONS_LEARNED.md)** - Por qué fallaron las optimizaciones MPI
- **[`opt/reports/PROFILING_SUMMARY.md`](opt/reports/PROFILING_SUMMARY.md)** - Resumen ejecutivo profiling

### Estructura del Proyecto
```
PY2-Paralela/
├── src/                    # Código fuente (6 algoritmos MPI)
├── build_bins_opt/         # Binarios optimizados (+2.1%)
├── scripts/                # Scripts del pipeline y benchmarks
├── opt/                    # Optimizaciones avanzadas y profiling
│   ├── reports/           # �� Reportes de profiling y análisis
│   ├── scripts/           # Scripts de profiling automatizados
│   └── src/               # Implementaciones experimentales
├── artifacts/              # Resultados de benchmarks (CSV/JSON)
│   ├── round0-*/          # Exploración inicial
│   ├── round1a-*/         # Comparación algorítmica
│   ├── round1b-*/         # Tuning
│   ├── round2-*/          # Final
│   └── scaling_round3-*/  # Scaling analysis
└── README.md              # Este archivo
```

---

## 🎯 Conclusiones Principales

### ✅ Has Alcanzado el Techo de Eficiencia

**Evidencia:**
- 🔬 Profiling: DES kernel 67%, MPI overhead <1%
- 📊 Benchmarks: +2.1% última mejora posible con compiler flags
- 🧪 9 optimizaciones probadas, solo 1 funcionó
- 📈 Scaling: límite teórico de Amdahl alcanzado (P=8)

**Límites identificados:**
1. **DES kernel (67%):** OpenSSL ya optimizado en assembly
2. **MPI overhead (<1%):** Ya minimizado en cyclic baseline
3. **Amdahl's Law:** 12% serial → speedup máximo ~8.3x
4. **Early-stop crítico:** Ahorra 98% de keys, no sacrificar

**Recomendación:** cyclic + compiler flags es óptimo para este workload

---

## 🧪 Experimental: Hybrid MPI+OpenMP

**Nueva implementación híbrida disponible:** `src/hybrid/bruteforce_mpi_cyclic_omp.c`

Combina paralelización MPI (entre procesos) con OpenMP (dentro de cada proceso) para explorar mejora adicional en memoria compartida.

```bash
# Compilar versión híbrida
bash scripts/compile_hybrid_omp.sh

# Ejecutar (ejemplo: 4 procesos MPI × 2 hilos OpenMP = 8 workers)
export OMP_NUM_THREADS=2
mpirun -np 4 ./build_bins_opt/bruteforce_mpi_cyclic_omp \
  -c data/cipher.bin -s "es una prueba de" -L 0 -U 8388608

# Benchmark automatizado
bash scripts/benchmark_hybrid_omp.sh
```

**Documentación completa:** Ver [`src/hybrid/README.md`](src/hybrid/README.md)

**Mejora esperada:** 1.05x-1.15x vs MPI puro en nodos con memoria compartida (8+ cores)

---

## 📚 Cómo Usar Esta Documentación


**Para reproducir:**
1. Ejecutar `bash scripts/validate_reproducibility.sh` - Validar setup
2. Correr `bash scripts/round3_scaling.sh` - Benchmark rápido
3. Ejecutar `bash opt/scripts/profile_des_kernel.sh` - Profiling completo

---

## 🏆 Créditos

**Proyecto:** PY2-Paralela  
**Autor:** mar22266  
**Fecha:** Octubre 2025  
**Estado:** ✅ Completo y validado
