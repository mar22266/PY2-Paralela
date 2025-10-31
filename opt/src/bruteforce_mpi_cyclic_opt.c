// ============================================================================
// bruteforce_mpi_cyclic_opt.c - Cyclic Optimizado con Chunking
// ============================================================================
// Optimizaciones:
// 1. Chunking interno: Procesa B keys antes de check MPI (reduce overhead)
// 2. Sync frequency: Solo chequea MPI cada N chunks (no cada key)
// 3. CPU affinity: Use mpirun --bind-to core --map-by core
// 4. Compile flags: -O3 -march=native -flto
// ============================================================================

#include "des_utils.h"
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>

// Parse uint64 from hex or decimal
static uint64_t parse_u64(const char *s){
    return (s[0]=='0'&&(s[1]=='x'||s[1]=='X'))? strtoull(s,NULL,16): strtoull(s,NULL,10);
}

// Banner
static void banner(void){
    puts("============================================================");
    puts("  BruteDES • MPI Cyclic OPTIMIZED");
    puts("  - Chunked processing with reduced sync overhead");
    puts("  - Parameters: -B <chunk_size> --sync-freq <N>");
    puts("============================================================\n");
}

// Usage
static void usage(const char *p){
    banner();
    fprintf(stderr, "USO:\n");
    fprintf(stderr, "  mpirun -np <P> --bind-to core --map-by core %s \\\n", p);
    fprintf(stderr, "    -c <cipher.bin> -s \"substring\" \\\n");
    fprintf(stderr, "    [-L low] [-U up) \\\n");
    fprintf(stderr, "    [-B chunk_size] [--sync-freq N] [--no-stop]\n\n");
    fprintf(stderr, "Parámetros de optimización:\n");
    fprintf(stderr, "  -B <chunk_size>    Número de keys por chunk (default: 50000)\n");
    fprintf(stderr, "  --sync-freq <N>    Checkear MPI cada N chunks (default: 8)\n");
    fprintf(stderr, "  --no-stop          Desactivar early-stop\n");
}

int main(int argc, char **argv){
    // Parse arguments
    const char *cipher_path=NULL, *needle=NULL;
    uint64_t L=0, U=(1ULL<<24);
    int chunk_B = 50000;        // Default chunk size
    int sync_freq = 8;          // Default sync frequency
    int no_stop = 0;
    
    for(int i=1; i<argc; i++){
        if(!strcmp(argv[i],"-c") && i+1<argc) cipher_path=argv[++i];
        else if(!strcmp(argv[i],"-s") && i+1<argc) needle=argv[++i];
        else if(!strcmp(argv[i],"-L") && i+1<argc) L=parse_u64(argv[++i]);
        else if(!strcmp(argv[i],"-U") && i+1<argc) U=parse_u64(argv[++i]);
        else if(!strcmp(argv[i],"-B") && i+1<argc) chunk_B=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--sync-freq") && i+1<argc) sync_freq=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--no-stop")) no_stop=1;
        else if(!strcmp(argv[i],"-h")){ usage(argv[0]); return 0; }
    }
    
    // Validate
    if(!cipher_path || !needle){ usage(argv[0]); return 1; }
    if(chunk_B <= 0) chunk_B = 50000;
    if(sync_freq <= 0) sync_freq = 8;
    
    // MPI Init
    MPI_Init(&argc, &argv);
    MPI_Comm comm = MPI_COMM_WORLD;
    int P, id;
    MPI_Comm_size(comm, &P);
    MPI_Comm_rank(comm, &id);
    
    if(id == 0){
        banner();
        printf("→ Configuración optimizada:\n");
        printf("  • Procesos     : %d\n", P);
        printf("  • Chunk size   : %d keys\n", chunk_B);
        printf("  • Sync freq    : cada %d chunks\n", sync_freq);
        printf("  • Early-stop   : %s\n\n", no_stop ? "desactivado" : "activado");
    }
    
    // Load cipher (rank 0)
    unsigned char *cipher = NULL;
    size_t clen = 0;
    int nlen = (int)strlen(needle);
    
    if(id == 0){
        if(read_whole_file(cipher_path, &cipher, &clen) != 0){
            fprintf(stderr, "ERROR leyendo %s\n", cipher_path);
            MPI_Abort(comm, 2);
        }
    }
    
    // Broadcast cipher size and content
    unsigned long long clen_ull = (id==0) ? (unsigned long long)clen : 0ULL;
    MPI_Bcast(&clen_ull, 1, MPI_UNSIGNED_LONG_LONG, 0, comm);
    clen = (size_t)clen_ull;
    
    if(id != 0) cipher = (unsigned char*)malloc(clen);
    MPI_Bcast(cipher, (int)clen, MPI_BYTE, 0, comm);
    
    // Broadcast needle
    MPI_Bcast(&nlen, 1, MPI_INT, 0, comm);
    char *needle_b = (char*)malloc(nlen + 1);
    if(id == 0) memcpy(needle_b, needle, nlen + 1);
    MPI_Bcast(needle_b, nlen + 1, MPI_CHAR, 0, comm);
    
    // Setup early-stop
    uint64_t found = UINT64_MAX;
    uint64_t local_tests = 0;
    int status_code = 0;
    int found_rank = -1;
    const int allow_stop = !no_stop;
    
    MPI_Request req = MPI_REQUEST_NULL;
    MPI_Status st;
    
    if(allow_stop){
        MPI_Irecv(&found, 1, MPI_UINT64_T, MPI_ANY_SOURCE, 777, comm, &req);
    }
    
    // ========================================================================
    // OPTIMIZED CHUNKED LOOP
    // ========================================================================
    MPI_Barrier(comm);
    double t0 = MPI_Wtime();
    
    uint64_t chunks_processed = 0;
    int early_stop_triggered = 0;
    
    // Calculate total chunks and assign cyclically
    uint64_t total_range = U - L;
    uint64_t total_chunks = (total_range + chunk_B - 1) / chunk_B;
    
    // Each rank processes chunks: my_rank, my_rank+P, my_rank+2P, ...
    for(uint64_t chunk_idx = (uint64_t)id; 
        chunk_idx < total_chunks && !early_stop_triggered; 
        chunk_idx += (uint64_t)P){
        
        // Calculate this chunk's range
        uint64_t chunk_start = L + chunk_idx * chunk_B;
        uint64_t chunk_end = chunk_start + chunk_B;
        if(chunk_end > U) chunk_end = U;
        
        // Inner loop: process ALL keys in this chunk consecutively
        for(uint64_t k = chunk_start; k < chunk_end; k++){
            local_tests++;
            
            if(des_try_key(k, cipher, clen, needle_b)){
                if(found == UINT64_MAX){
                    found = k;
                    status_code = 2;
                    found_rank = id;
                }
                
                // Notify all ranks
                if(allow_stop){
                    for(int p=0; p<P; p++){
                        MPI_Send(&found, 1, MPI_UINT64_T, p, 777, comm);
                    }
                    early_stop_triggered = 1;
                    break;
                }
            }
        }
        
        chunks_processed++;
        
        // Check for early-stop ONLY every sync_freq chunks
        if(allow_stop && (chunks_processed % sync_freq == 0)){
            int flag = 0;
            MPI_Test(&req, &flag, &st);
            if(flag){
                status_code = 1;
                early_stop_triggered = 1;
            }
        }
    }
    
    MPI_Barrier(comm);
    double t1 = MPI_Wtime();
    double local_time = t1 - t0;
    
    // Cleanup early-stop request
    if(allow_stop && req != MPI_REQUEST_NULL){
        int completed = 0;
        MPI_Test(&req, &completed, &st);
        if(!completed){
            MPI_Cancel(&req);
            MPI_Wait(&req, &st);
        }
    }
    
    if(!allow_stop && status_code == 0 && found != UINT64_MAX){
        status_code = 2;
    }
    
    // ========================================================================
    // GATHER RESULTS
    // ========================================================================
    double *times_all = NULL;
    uint64_t *tests_all = NULL;
    int *status_all = NULL;
    int *rf_all = NULL;
    
    if(id == 0){
        times_all = (double*)malloc(sizeof(double) * P);
        tests_all = (uint64_t*)malloc(sizeof(uint64_t) * P);
        status_all = (int*)malloc(sizeof(int) * P);
        rf_all = (int*)malloc(sizeof(int) * P);
    }
    
    MPI_Gather(&local_time, 1, MPI_DOUBLE, times_all, 1, MPI_DOUBLE, 0, comm);
    MPI_Gather(&local_tests, 1, MPI_UINT64_T, tests_all, 1, MPI_UINT64_T, 0, comm);
    MPI_Gather(&status_code, 1, MPI_INT, status_all, 1, MPI_INT, 0, comm);
    MPI_Gather(&found_rank, 1, MPI_INT, rf_all, 1, MPI_INT, 0, comm);
    
    double t_par_max = 0.0;
    MPI_Reduce(&local_time, &t_par_max, 1, MPI_DOUBLE, MPI_MAX, 0, comm);
    
    uint64_t found_global = UINT64_MAX;
    MPI_Reduce(&found, &found_global, 1, MPI_UINT64_T, MPI_MIN, 0, comm);
    
    // ========================================================================
    // REPORT
    // ========================================================================
    if(id == 0){
        printf("  • Archivo  : %s (bytes=%zu)\n", cipher_path, clen);
        printf("  • Subcadena: \"%s\"\n", needle_b);
        printf("  • Rango    : [%" PRIu64 ", %" PRIu64 ")\n\n", L, U);
        
        puts("  • Detalle por proceso");
        puts("    RANK |   TESTS    |  CHUNKS  |  STATUS           |  TIME(s)");
        puts("    -----+------------+----------+-------------------+---------");
        
        uint64_t sum = 0;
        int who = -1;
        
        for(int r=0; r<P; r++){
            const char* stxt = (status_all[r]==2) ? "FOUND" : 
                              (status_all[r]==1) ? "STOP(SIGNAL)" : 
                              "DONE(RANGE)";
            
            uint64_t est_chunks = tests_all[r] / chunk_B + 1;
            
            printf("    %4d | %10" PRIu64 " | %8" PRIu64 " | %-17s | %7.4f\n",
                   r, tests_all[r], est_chunks, stxt, times_all[r]);
            
            sum += tests_all[r];
            if(status_all[r] == 2) who = r;
        }
        
        // Decrypt if found
        if(found_global != UINT64_MAX){
            unsigned char *plain = (unsigned char*)malloc(clen + 1);
            des_decrypt_buffer(found_global, cipher, clen, plain);
            plain[clen] = 0;
            
            puts("\n  • Resultado: ✔ Llave encontrada");
            printf("    - Rank    : %d\n", (who>=0 ? who : rf_all[0]));
            printf("    - Llave   : %" PRIu64 " (0x%016" PRIx64 ")\n", 
                   found_global, found_global);
            printf("    - Texto   : %s\n", plain);
            free(plain);
        } else {
            puts("\n  • Resultado: ✘ No encontrada");
        }
        
        puts("\n  • Resumen global");
        printf("    - Llaves probadas totales  : %" PRIu64 "\n", sum);
        printf("    - Tiempo total (max rank): %.6f s\n", t_par_max);
        
        // Calculate per-rank statistics
        double mean_time = 0.0, min_time = times_all[0], max_time = times_all[0];
        for(int r=0; r<P; r++){
            mean_time += times_all[r];
            if(times_all[r] < min_time) min_time = times_all[r];
            if(times_all[r] > max_time) max_time = times_all[r];
        }
        mean_time /= P;
        
        double imbalance_pct = ((max_time - min_time) / max_time) * 100.0;
        
        printf("    - Tiempo medio por rank    : %.6f s\n", mean_time);
        printf("    - Tiempo min/max           : %.6f / %.6f s\n", min_time, max_time);
        printf("    - Imbalance                : %.2f%%\n", imbalance_pct);
        
        // Standardized metrics for pipeline parsing
        printf("\nrank_found: %d\n", (who>=0 ? who : -1));
        printf("tests_total: %" PRIu64 "\n", sum);
        printf("Tiempo total (max rank): %.6f s\n", t_par_max);
        fflush(stdout);
        
        free(times_all);
        free(tests_all);
        free(status_all);
        free(rf_all);
    }
    
    // Cleanup
    free(cipher);
    free(needle_b);
    MPI_Barrier(comm);
    MPI_Finalize();
    return 0;
}
