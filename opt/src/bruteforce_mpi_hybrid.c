// ============================================================================
// bruteforce_mpi_hybrid.c - Híbrido simplificado: Cyclic con early-stop eficiente
// ============================================================================
// Estrategia simplificada:
// 1. Todos procesan en modo cyclic (chunked)
// 2. Solo check MPI cada N chunks (reducir overhead)
// 3. Cuando alguien encuentra, broadcast inmediato
// 4. Sin master coordinator - pure SPMD
//
// Esta versión es más simple y evita el overhead del monitoring.
// La "adaptación" viene del chunk size configurable.
// ============================================================================

#include "des_utils.h"
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>
#include <string.h>

static void banner(void){
    puts("============================================================");
    puts("  BruteDES • MPI HYBRID (Cyclic con sync adaptable)");
    puts("  - Pure SPMD cyclic con configuración de chunk y sync");
    puts("  - Sin coordinator overhead");
    puts("============================================================\n");
}

static void usage(const char *p){
    banner();
    fprintf(stderr, "USO:\n");
    fprintf(stderr, "  mpirun -np <P> %s \\\n", p);
    fprintf(stderr, "    -c <cipher.bin> -s \"substring\" \\\n");
    fprintf(stderr, "    [-L low] [-U up) [-B chunk_size] [--sync-freq N]\n\n");
    fprintf(stderr, "Parámetros:\n");
    fprintf(stderr, "  -B <chunk_size>    Tamaño de chunk cyclic (default: 50000)\n");
    fprintf(stderr, "  --sync-freq <N>    Check MPI cada N chunks (default: 4)\n");
}

int main(int argc, char **argv){
    MPI_Init(&argc, &argv);
    MPI_Comm comm = MPI_COMM_WORLD;
    int P = 1, id = 0;
    MPI_Comm_size(comm, &P);
    MPI_Comm_rank(comm, &id);
    
    // Parse arguments
    const char *cipher_path = NULL, *needle = NULL;
    uint64_t L = 0, U = (1ULL << 24);
    int chunk_B = 50000;
    int sync_freq = 4;
    
    for(int i = 1; i < argc; i++){
        if(!strcmp(argv[i], "-c") && i+1 < argc) cipher_path = argv[++i];
        else if(!strcmp(argv[i], "-s") && i+1 < argc) needle = argv[++i];
        else if(!strcmp(argv[i], "-L") && i+1 < argc) L = strtoull(argv[++i], NULL, 10);
        else if(!strcmp(argv[i], "-U") && i+1 < argc) U = strtoull(argv[++i], NULL, 10);
        else if(!strcmp(argv[i], "-B") && i+1 < argc) chunk_B = atoi(argv[++i]);
        else if(!strcmp(argv[i], "--sync-freq") && i+1 < argc) sync_freq = atoi(argv[++i]);
        else if(!strcmp(argv[i], "-h")){ usage(argv[0]); MPI_Finalize(); return 0; }
    }
    
    if(!cipher_path || !needle){ usage(argv[0]); MPI_Finalize(); return 1; }
    if(chunk_B <= 0) chunk_B = 50000;
    if(sync_freq <= 0) sync_freq = 4;
    
    if(id == 0){
        banner();
        printf("→ Configuración:\n");
        printf("  • Procesos       : %d\n", P);
        printf("  • Chunk size     : %d keys\n", chunk_B);
        printf("  • Sync frequency : cada %d chunks\n\n", sync_freq);
    }
    
    // Load cipher
    unsigned char *cipher = NULL;
    size_t clen = 0;
    int nlen = (int)strlen(needle);
    
    if(id == 0){
        if(read_whole_file(cipher_path, &cipher, &clen) != 0){
            fprintf(stderr, "ERROR leyendo %s\n", cipher_path);
            MPI_Abort(comm, 2);
        }
    }
    
    unsigned long long clen_ull = (id == 0) ? (unsigned long long)clen : 0ULL;
    MPI_Bcast(&clen_ull, 1, MPI_UNSIGNED_LONG_LONG, 0, comm);
    clen = (size_t)clen_ull;
    
    if(id != 0) cipher = (unsigned char*)malloc(clen);
    MPI_Bcast(cipher, (int)clen, MPI_BYTE, 0, comm);
    
    // Broadcast needle
    MPI_Bcast(&nlen, 1, MPI_INT, 0, comm);
    char *needle_b = (char*)malloc(nlen + 1);
    if(id == 0) memcpy(needle_b, needle, nlen + 1);
    MPI_Bcast(needle_b, nlen + 1, MPI_CHAR, 0, comm);
    
    MPI_Barrier(comm);
    double t0 = MPI_Wtime();
    
    // State
    uint64_t local_tests = 0;
    uint64_t found = UINT64_MAX;
    int found_rank = -1;
    int status_code = 0;
    int early_stop = 0;
    
    // Calculate cyclic chunk assignments
    uint64_t total_range = U - L;
    uint64_t total_chunks = (total_range + chunk_B - 1) / chunk_B;
    
    if(id == 0){
        printf("  • Rango          : [%" PRIu64 ", %" PRIu64 ")\n", L, U);
        printf("  • Total chunks   : %" PRIu64 "\n\n", total_chunks);
        printf("→ Procesando...\n\n");
        fflush(stdout);
    }
    
    // ========================================================================
    // CYCLIC EXECUTION with periodic MPI checks
    // ========================================================================
    
    uint64_t my_chunk_idx = (uint64_t)id;
    int chunks_processed = 0;
    
    while(my_chunk_idx < total_chunks && !early_stop){
        // Calculate this chunk's range
        uint64_t chunk_start = L + my_chunk_idx * chunk_B;
        uint64_t chunk_end = chunk_start + chunk_B;
        if(chunk_end > U) chunk_end = U;
        
        // Process chunk
        for(uint64_t k = chunk_start; k < chunk_end && !early_stop; k++){
            local_tests++;
            
            if(des_try_key(k, cipher, clen, needle_b)){
                if(found == UINT64_MAX){
                    found = k;
                    status_code = 2;
                    found_rank = id;
                    early_stop = 1;
                    break;
                }
            }
        }
        
        // Move to next cyclic chunk
        my_chunk_idx += (uint64_t)P;
        chunks_processed++;
        
        // Periodic MPI check for early-stop
        if(chunks_processed % sync_freq == 0 || early_stop){
            // Check if someone found it
            int flag = 0;
            MPI_Status st;
            uint64_t recv_key;
            
            MPI_Iprobe(MPI_ANY_SOURCE, MPI_ANY_TAG, comm, &flag, &st);
            while(flag){
                MPI_Recv(&recv_key, 1, MPI_UINT64_T, st.MPI_SOURCE, st.MPI_TAG, comm, &st);
                if(recv_key < found){
                    found = recv_key;
                    found_rank = st.MPI_SOURCE;
                }
                early_stop = 1;
                MPI_Iprobe(MPI_ANY_SOURCE, MPI_ANY_TAG, comm, &flag, &st);
            }
            
            // If I found, notify others
            if(status_code == 2){
                for(int p = 0; p < P; p++){
                    if(p != id){
                        MPI_Send(&found, 1, MPI_UINT64_T, p, 99, comm);
                    }
                }
            }
        }
    }
    
    MPI_Barrier(comm);
    double t1 = MPI_Wtime();
    double local_time = t1 - t0;
    
    // ========================================================================
    // GATHER RESULTS
    // ========================================================================
    double *times_all = NULL;
    uint64_t *tests_all = NULL;
    int *status_all = NULL;
    
    if(id == 0){
        times_all = (double*)malloc(sizeof(double) * P);
        tests_all = (uint64_t*)malloc(sizeof(uint64_t) * P);
        status_all = (int*)malloc(sizeof(int) * P);
    }
    
    MPI_Gather(&local_time, 1, MPI_DOUBLE, times_all, 1, MPI_DOUBLE, 0, comm);
    MPI_Gather(&local_tests, 1, MPI_UINT64_T, tests_all, 1, MPI_UINT64_T, 0, comm);
    MPI_Gather(&status_code, 1, MPI_INT, status_all, 1, MPI_INT, 0, comm);
    
    double t_par_max = 0.0;
    MPI_Reduce(&local_time, &t_par_max, 1, MPI_DOUBLE, MPI_MAX, 0, comm);
    
    uint64_t found_global = UINT64_MAX;
    MPI_Reduce(&found, &found_global, 1, MPI_UINT64_T, MPI_MIN, 0, comm);
    
    if(id == 0){
        printf("  • Detalle por proceso\n");
        printf("    RANK |   TESTS    |  STATUS           |  TIME(s)\n");
        printf("    -----+------------+-------------------+---------\n");
        
        uint64_t sum = 0;
        int who = -1;
        
        for(int r = 0; r < P; r++){
            const char* stxt = (status_all[r] == 2) ? "FOUND" :
                              (status_all[r] == 1) ? "STOP(SIGNAL)" :
                              "DONE(RANGE)";
            printf("    %4d | %10" PRIu64 " | %-17s | %7.4f\n",
                   r, tests_all[r], stxt, times_all[r]);
            sum += tests_all[r];
            if(status_all[r] == 2) who = r;
        }
        
        if(found_global != UINT64_MAX){
            unsigned char *plain = (unsigned char*)malloc(clen + 1);
            des_decrypt_buffer(found_global, cipher, clen, plain);
            plain[clen] = 0;
            
            printf("\n  • Resultado: ✔ Llave encontrada\n");
            printf("    - Rank    : %d\n", who);
            printf("    - Llave   : %" PRIu64 "\n", found_global);
            printf("    - Texto   : %s\n", plain);
            free(plain);
        } else {
            printf("\n  • Resultado: ✘ No encontrada\n");
        }
        
        printf("\n  • Resumen global\n");
        printf("    - Llaves probadas totales  : %" PRIu64 "\n", sum);
        printf("    - Tiempo total (max rank)  : %.6f s\n", t_par_max);
        
        // Standardized output
        printf("\nrank_found: %d\n", who);
        printf("tests_total: %" PRIu64 "\n", sum);
        printf("Tiempo total (max rank): %.6f s\n", t_par_max);
        fflush(stdout);
        
        free(times_all);
        free(tests_all);
        free(status_all);
    }
    
    free(cipher);
    free(needle_b);
    MPI_Finalize();
    return 0;
}
