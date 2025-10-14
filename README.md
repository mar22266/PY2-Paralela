PY2-Paralela — Brute-force DES (MPI)
------------------------------------

Romper DES por fuerza bruta. Incluye una versión secuencial y cinco enfoques paralelos con MPI: naïve (bloques), cíclico, dinámico, dinámico-adaptativo y permutado. Se mide tiempo secuencial, tiempo paralelo (tₚ = max rank) y speedup = tₛ / tₚ. Usa OpenSSL (libcrypto) para DES.

Qué hace
-----------

*   Cifra un texto de prueba con una “llave” (entero) para generar un cipher.bin.
    
*   Busca la llave probando candidatas en un rango \[L,U).
    
*   Descifra el buffer en memoria con cada candidata.
    
*   Verifica si el texto claro contiene la subcadena objetivo.
    
*   Difunde _early-stop_ al encontrar la llave.
    

Estrategias de paralelización
-------------------------------------------

| Binario | Estrategia | Idea |
| --- | --- | --- |
| `bin/bruteforce_seq` | Secuencial | Recorre todo el rango en un solo proceso. |
| `bin/bruteforce_mpi` | Naïve (bloques contiguos) | Divide `[L,U)` en P bloques, 1 por proceso. Overhead mínimo, varianza alta. |
| `bin/bruteforce_mpi_cyclic` | Cíclico (round-robin) | Cada rank prueba `k = k0 + rank`, `k += P`. Balance simple. |
| `bin/bruteforce_mpi_dynamic` | Dinámico (master-worker, `-B`) | Maestro asigna chunks de tamaño `B` a quien termina. Balancea heterogeneidad. |
| `bin/bruteforce_mpi_dynamic_adaptive` | Dinámico-adaptativo (master-worker, `-T`) | Ajusta `B` para que cada chunk dure ≈ `T` ms según throughput observado. Menor varianza. |
| `bin/bruteforce_mpi_permuted` | Permutado (stride/LCG, `-R`) | “Baraja” el orden de llaves con una permutación/semilla `R`; reduce sesgo espacial. |

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
    

* * *

## 🔧 Compilación

`make            # genera binarios en ./bin`

## Ejemplos de uso

### Secuencial

## 

`./bin/bruteforce_seq --encrypt -i data/mensaje.txt -k 57920 -o data/cipher.bin ./bin/bruteforce_seq --bruteforce -c data/cipher.bin -s "es una prueba de" -L 0 -U 16777216`

### Paralelo (4 procesos de ejemplo)

## 

`mpirun -np 4 ./bin/bruteforce_mpi                     -c data/cipher.bin -s "es una prueba de" -L 0 -U 16777216 mpirun -np 4 ./bin/bruteforce_mpi_cyclic              -c data/cipher.bin -s "es una prueba de" -L 0 -U 16777216 mpirun -np 4 ./bin/bruteforce_mpi_dynamic             -c data/cipher.bin -s "es una prueba de" -L 0 -U 16777216 -B 50000 mpirun -np 4 ./bin/bruteforce_mpi_dynamic_adaptive   -c data/cipher.bin -s "es una prueba de" -L 0 -U 16777216 -T 30 mpirun -np 4 ./bin/bruteforce_mpi_permuted            -c data/cipher.bin -s "es una prueba de" -L 0 -U 16777216 -R 12345`

* * *

## 🔍 Salida típica (paralelo)

## 

**Detalle por proceso**

`RANK | TESTS | STATUS        | TIME(s) -----+-------+---------------+--------   0  | 28672 | STOP(SIGNAL)  | 0.0221   3  | 26891 | FOUND         | 0.0209  <==`

**Resultado:** ✔ Llave encontrada

-   Rank : 3
    
-   Llave: 57920
    
-   Tiempo total (max rank): 0.022228 s

  

