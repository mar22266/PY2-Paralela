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
make
```


## Ejemplos de uso
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


