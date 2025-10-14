PY2-Paralela — Brute-force DES (MPI)
------------------------------------

**Resumen:**Proyecto académico para romper DES por fuerza bruta. Incluye una versión secuencial y cinco enfoques paralelos con MPI: naïve (bloques), cíclico, dinámico, dinámico-adaptativo y permutado. Se mide tiempo secuencial, tiempo paralelo (tₚ = max rank) y speedup = tₛ / tₚ. Usa OpenSSL (libcrypto) para DES.

Qué hace
-----------

*   Cifra un texto de prueba con una “llave” (entero) para generar un cipher.bin.
    
*   Busca la llave probando candidatas en un rango \[L,U).
    
*   Descifra el buffer en memoria con cada candidata.
    
*   Verifica si el texto claro contiene la subcadena objetivo.
    
*   Difunde _early-stop_ al encontrar la llave.
    

Estrategias de paralelización
-------------------------------------------

BinarioEstrategiaIdeabin/bruteforce\_seqSecuencialRecorre todo el rango en un solo proceso.bin/bruteforce\_mpiNaïve (bloques contiguos)Divide \[L,U) en P bloques, 1 por proceso. Overhead mínimo, varianza alta.bin/bruteforce\_mpi\_cyclicCíclico (round-robin)Cada rank prueba k = k0 + rank, k += P. Balance simple.bin/bruteforce\_mpi\_dynamicDinámico (master-worker, -B)Maestro asigna chunks de tamaño B a quien termina. Balancea heterogeneidad.bin/bruteforce\_mpi\_dynamic\_adaptiveDinámico-adaptativo (master-worker, -T)Ajusta B para que cada chunk dure ≈ T ms según throughput observado. Menor varianza.bin/bruteforce\_mpi\_permutedPermutado (stride/LCG, -R)“Baraja” el orden de llaves con una permutación/semilla R; reduce sesgo espacial.

**Parámetros comunes:**

*   \-c : ruta del cipher.bin
    
*   \-s "": subcadena a buscar en el texto claro
    
*   \-L \-U : rango de llaves \[L,U)
    

**Parámetros por variante:**

*   Dinámico: -B
    
*   Dinámico-adaptativo: -T
    
*   Permutado: -R
