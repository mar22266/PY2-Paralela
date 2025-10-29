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
