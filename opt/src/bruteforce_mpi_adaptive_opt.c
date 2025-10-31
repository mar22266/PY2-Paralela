// ============================================================================
// bruteforce_mpi_adaptive_opt.c - Adaptive Optimizado con Batching
// ============================================================================
// Optimizaciones:
// 1. Batch requests: Workers solicitan múltiples chunks a la vez
// 2. Non-blocking probes: MPI_Iprobe en lugar de blocking
// 3. Hysteresis: No ajustar chunk size si cambio es pequeño
// 4. Lazy feedback: Actualizar throughput cada K chunks, no cada uno
// 5. Exponential backoff: Reducir frecuencia de requests si idle
// ============================================================================

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 199309L
#endif

#include "des_utils.h"
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>
#include <string.h>
#include <math.h>

// Message tags
enum { TAG_REQ=1, TAG_TASK_BATCH=2, TAG_FOUND=3, TAG_STOP=4 };

#define MAX_BATCH_SIZE 16

// Chunk structure for batching
typedef struct {
    uint64_t start;
    uint64_t end;
} chunk_t;

// Load file
static int load_file(const char *path, unsigned char **buf, size_t *len){
    FILE *f = fopen(path, "rb");
    if(!f) return -1;
    if(fseek(f, 0, SEEK_END) != 0){ fclose(f); return -1; }
    long n = ftell(f);
    if(n < 0){ fclose(f); return -1; }
    rewind(f);
    *buf = (unsigned char*)malloc((size_t)n);
    if(!*buf){ fclose(f); return -1; }
    if(fread(*buf, 1, (size_t)n, f) != (size_t)n){
        fclose(f);
        free(*buf);
        return -1;
    }
    fclose(f);
    *len = (size_t)n;
    return 0;
}

static void banner(void){
    puts("============================================================");
    puts("  BruteDES • MPI Adaptive OPTIMIZED");
    puts("  - Batched requests with reduced communication");
    puts("  - Parameters: --batch <N> --hysteresis <pct>");
    puts("============================================================\n");
}

static void usage(const char *p){
    banner();
    fprintf(stderr, "USO:\n");
    fprintf(stderr, "  mpirun -np <P> %s \\\n", p);
    fprintf(stderr, "    -c <cipher.bin> -s \"substring\" \\\n");
    fprintf(stderr, "    [-L low] [-U up) \\\n");
    fprintf(stderr, "    [-T target_ms] [--batch N] [--hysteresis pct] [--feedback-freq K]\n\n");
    fprintf(stderr, "Parámetros de optimización:\n");
    fprintf(stderr, "  -T <target_ms>       Target time per chunk (default: 30.0 ms)\n");
    fprintf(stderr, "  --batch <N>          Chunks por request (default: 4)\n");
    fprintf(stderr, "  --hysteresis <pct>   Min cambio para ajustar chunk (default: 0.15 = 15%%)\n");
    fprintf(stderr, "  --feedback-freq <K>  Actualizar throughput cada K chunks (default: 5)\n");
}

int main(int argc, char **argv){
    MPI_Init(&argc, &argv);
    MPI_Comm comm = MPI_COMM_WORLD;
    int P = 1, id = 0;
    MPI_Comm_size(comm, &P);
    MPI_Comm_rank(comm, &id);
    
    if(P < 2){
        if(id == 0) fprintf(stderr, "Se requieren al menos 2 procesos (1 maestro + workers)\n");
        MPI_Finalize();
        return 1;
    }
    
    // Parse arguments
    const char *cpath = NULL, *needle_cli = NULL;
    uint64_t L = 0, U = (1ULL << 24);
    double target_ms = 30.0;
    int batch_size = 4;           // Optimizado: batch requests
    double hysteresis = 0.15;     // 15% threshold
    int feedback_freq = 5;        // Update every 5 chunks
    
    for(int i = 1; i < argc; i++){
        if(!strcmp(argv[i], "-c") && i+1 < argc) cpath = argv[++i];
        else if(!strcmp(argv[i], "-s") && i+1 < argc) needle_cli = argv[++i];
        else if(!strcmp(argv[i], "-L") && i+1 < argc) L = strtoull(argv[++i], NULL, 10);
        else if(!strcmp(argv[i], "-U") && i+1 < argc) U = strtoull(argv[++i], NULL, 10);
        else if(!strcmp(argv[i], "-T") && i+1 < argc) target_ms = strtod(argv[++i], NULL);
        else if(!strcmp(argv[i], "--batch") && i+1 < argc) batch_size = atoi(argv[++i]);
        else if(!strcmp(argv[i], "--hysteresis") && i+1 < argc) hysteresis = strtod(argv[++i], NULL);
        else if(!strcmp(argv[i], "--feedback-freq") && i+1 < argc) feedback_freq = atoi(argv[++i]);
        else if(!strcmp(argv[i], "-h")){ usage(argv[0]); MPI_Finalize(); return 0; }
    }
    
    if(!cpath || !needle_cli || U <= L){
        if(id == 0) usage(argv[0]);
        MPI_Finalize();
        return 2;
    }
    
    // Validate parameters
    if(batch_size <= 0 || batch_size > MAX_BATCH_SIZE) batch_size = 4;
    if(hysteresis < 0.0 || hysteresis > 1.0) hysteresis = 0.15;
    if(feedback_freq <= 0) feedback_freq = 5;
    
    if(id == 0){
        banner();
        printf("→ Configuración optimizada:\n");
        printf("  • Procesos       : %d (1 maestro + %d workers)\n", P, P-1);
        printf("  • Target time    : %.1f ms\n", target_ms);
        printf("  • Batch size     : %d chunks\n", batch_size);
        printf("  • Hysteresis     : %.1f%%\n", hysteresis * 100.0);
        printf("  • Feedback freq  : cada %d chunks\n\n", feedback_freq);
    }
    
    // Load and broadcast cipher
    unsigned char *cipher = NULL;
    size_t clen_sz = 0;
    
    if(id == 0){
        if(load_file(cpath, &cipher, &clen_sz) != 0){
            fprintf(stderr, "No pude leer %s\n", cpath);
            MPI_Abort(comm, 3);
        }
        if(clen_sz == 0 || (clen_sz % 8) != 0){
            fprintf(stderr, "El cifrado debe ser >0 y múltiplo de 8 bytes\n");
            MPI_Abort(comm, 4);
        }
    }
    
    uint64_t clen64 = (id == 0) ? (uint64_t)clen_sz : 0;
    MPI_Bcast(&clen64, 1, MPI_UINT64_T, 0, comm);
    
    if(id != 0){
        clen_sz = (size_t)clen64;
        cipher = (unsigned char*)malloc(clen_sz);
        if(!cipher){
            fprintf(stderr, "Rank %d: malloc cipher\n", id);
            MPI_Abort(comm, 5);
        }
    }
    MPI_Bcast(cipher, (int)clen_sz, MPI_UNSIGNED_CHAR, 0, comm);
    
    // Broadcast needle
    int nlen = 0;
    if(id == 0) nlen = (int)strlen(needle_cli);
    MPI_Bcast(&nlen, 1, MPI_INT, 0, comm);
    
    unsigned char *needle = (unsigned char*)malloc((size_t)nlen + 1);
    if(!needle){
        fprintf(stderr, "Rank %d: malloc needle\n", id);
        MPI_Abort(comm, 6);
    }
    if(id == 0) memcpy(needle, needle_cli, (size_t)nlen + 1);
    MPI_Bcast(needle, nlen + 1, MPI_UNSIGNED_CHAR, 0, comm);
    
    MPI_Barrier(comm);
    double t_global0 = MPI_Wtime();
    
    // ========================================================================
    // MASTER PROCESS - Optimized batch scheduler
    // ========================================================================
    if(id == 0){
        printf("  • Rango          : [%" PRIu64 ", %" PRIu64 ")\n\n", L, U);
        fflush(stdout);
        
        uint64_t next = L;
        const uint64_t end = U;
        
        // Per-worker state
        double last_send_t[1024];
        double thr_keys_s[1024];
        uint64_t cur_B[1024];
        
        for(int i = 0; i < 1024; i++){
            last_send_t[i] = 0.0;
            thr_keys_s[i] = 300000.0;  // Initial estimate
            cur_B[i] = 20000;          // Initial chunk size
        }
        
        int any_found = 0;
        int winner = -1;
        uint64_t found_key = 0;
        MPI_Status st;
        
        // Initial batch distribution
        for(int w = 1; w < P; ++w){
            int req_batch;
            MPI_Recv(&req_batch, 1, MPI_INT, w, TAG_REQ, comm, &st);
            
            chunk_t batch[MAX_BATCH_SIZE];
            int chunks_sent = 0;
            
            for(int b = 0; b < req_batch && next < end; b++){
                uint64_t B = cur_B[w];
                batch[b].start = next;
                batch[b].end = (next + B < end) ? (next + B) : end;
                if(batch[b].start < batch[b].end){
                    next = batch[b].end;
                    chunks_sent++;
                } else {
                    break;
                }
            }
            
            MPI_Send(batch, chunks_sent * sizeof(chunk_t), MPI_BYTE, w, TAG_TASK_BATCH, comm);
            last_send_t[w] = MPI_Wtime();
        }
        
        // Main scheduling loop with non-blocking probes
        while(!any_found && next < end){
            int flag = 0;
            MPI_Iprobe(MPI_ANY_SOURCE, MPI_ANY_TAG, comm, &flag, &st);
            
            if(!flag) continue;  // No message, continue probing
            
            int src = st.MPI_SOURCE;
            int tag = st.MPI_TAG;
            
            if(tag == TAG_FOUND){
                uint64_t k;
                MPI_Recv(&k, 1, MPI_UINT64_T, src, TAG_FOUND, comm, &st);
                any_found = 1;
                winner = src;
                found_key = k;
                
                // Send stop to all workers
                for(int w = 1; w < P; ++w){
                    MPI_Send(NULL, 0, MPI_BYTE, w, TAG_STOP, comm);
                }
                break;
                
            } else if(tag == TAG_REQ){
                int req_batch;
                MPI_Recv(&req_batch, 1, MPI_INT, src, TAG_REQ, comm, &st);
                
                // Update throughput estimate with hysteresis
                double now = MPI_Wtime();
                double dt = now - last_send_t[src];
                
                if(dt > 0.001){  // Avoid division by zero
                    double keys = (double)cur_B[src] * req_batch;  // Total keys from last batch
                    double new_thr = keys / dt;
                    
                    // EMA with alpha=0.3
                    thr_keys_s[src] = 0.7 * thr_keys_s[src] + 0.3 * new_thr;
                    
                    // Adjust chunk size with hysteresis
                    uint64_t new_B = (uint64_t)((target_ms / 1000.0) * thr_keys_s[src]);
                    if(new_B < 5000) new_B = 5000;
                    if(new_B > 500000) new_B = 500000;
                    
                    double change_pct = fabs((double)new_B - (double)cur_B[src]) / (double)cur_B[src];
                    
                    // Only update if change > hysteresis threshold
                    if(change_pct > hysteresis){
                        cur_B[src] = new_B;
                    }
                }
                
                // Send new batch
                chunk_t batch[MAX_BATCH_SIZE];
                int chunks_sent = 0;
                
                for(int b = 0; b < req_batch && next < end; b++){
                    uint64_t B = cur_B[src];
                    batch[b].start = next;
                    batch[b].end = (next + B < end) ? (next + B) : end;
                    if(batch[b].start < batch[b].end){
                        next = batch[b].end;
                        chunks_sent++;
                    } else {
                        break;
                    }
                }
                
                if(chunks_sent > 0){
                    MPI_Send(batch, chunks_sent * sizeof(chunk_t), MPI_BYTE, src, TAG_TASK_BATCH, comm);
                    last_send_t[src] = now;
                } else {
                    // No more work
                    chunk_t empty = {end, end};
                    MPI_Send(&empty, sizeof(chunk_t), MPI_BYTE, src, TAG_TASK_BATCH, comm);
                }
            }
        }
        
        // Wait for all workers to finish
        MPI_Barrier(comm);
        double t_global1 = MPI_Wtime();
        
        // Gather statistics
        double *times_all = (double*)malloc(sizeof(double) * P);
        uint64_t *tests_all = (uint64_t*)malloc(sizeof(uint64_t) * P);
        
        double master_time = t_global1 - t_global0;
        uint64_t master_tests = 0;
        
        MPI_Gather(&master_time, 1, MPI_DOUBLE, times_all, 1, MPI_DOUBLE, 0, comm);
        MPI_Gather(&master_tests, 1, MPI_UINT64_T, tests_all, 1, MPI_UINT64_T, 0, comm);
        
        // Print results
        printf("  • Detalle por proceso\n");
        printf("    RANK |   TESTS     |  TIME(s)\n");
        printf("    -----+-------------+---------\n");
        
        uint64_t total_tests = 0;
        for(int r = 0; r < P; r++){
            printf("    %4d | %11" PRIu64 " | %7.4f\n", r, tests_all[r], times_all[r]);
            total_tests += tests_all[r];
        }
        
        if(any_found){
            unsigned char *plain = (unsigned char*)malloc(clen_sz + 1);
            des_decrypt_buffer(found_key, cipher, clen_sz, plain);
            plain[clen_sz] = 0;
            
            printf("\n  • Resultado: ✔ Llave encontrada\n");
            printf("    - Rank    : %d\n", winner);
            printf("    - Llave   : %" PRIu64 "\n", found_key);
            printf("    - Texto   : %s\n", plain);
            free(plain);
        } else {
            printf("\n  • Resultado: ✘ No encontrada\n");
        }
        
        printf("\n  • Resumen global\n");
        printf("    - Tiempo total (max rank): %.6f s\n", t_global1 - t_global0);
        
        // Standardized output
        printf("\nrank_found: %d\n", any_found ? winner : -1);
        printf("tests_total: %" PRIu64 "\n", total_tests);
        printf("Tiempo total (max rank): %.6f s\n", t_global1 - t_global0);
        fflush(stdout);
        
        free(times_all);
        free(tests_all);
    }
    // ========================================================================
    // WORKER PROCESS - Optimized batch processing
    // ========================================================================
    else {
        uint64_t local_tests = 0;
        int found = 0;
        uint64_t found_key = 0;
        
        chunk_t batch[MAX_BATCH_SIZE];
        int chunks_to_process = 0;
        int chunks_processed_since_feedback = 0;
        
        MPI_Status st;
        int stop_received = 0;
        
        // Request initial batch
        MPI_Send(&batch_size, 1, MPI_INT, 0, TAG_REQ, comm);
        
        while(!stop_received && !found){
            // Receive batch (blocking)
            MPI_Recv(batch, MAX_BATCH_SIZE * sizeof(chunk_t), MPI_BYTE, 0, MPI_ANY_TAG, comm, &st);
            
            if(st.MPI_TAG == TAG_STOP){
                stop_received = 1;
                break;
            }
            
            // Determine number of chunks received
            int received_bytes;
            MPI_Get_count(&st, MPI_BYTE, &received_bytes);
            chunks_to_process = received_bytes / sizeof(chunk_t);
            
            if(chunks_to_process == 0 || batch[0].start >= batch[0].end){
                break;  // No more work
            }
            
            // Process all chunks in batch
            for(int c = 0; c < chunks_to_process && !found; c++){
                uint64_t start = batch[c].start;
                uint64_t end = batch[c].end;
                
                for(uint64_t k = start; k < end && !found; k++){
                    local_tests++;
                    
                    if(des_try_key(k, cipher, clen_sz, (char*)needle)){
                        found = 1;
                        found_key = k;
                        MPI_Send(&found_key, 1, MPI_UINT64_T, 0, TAG_FOUND, comm);
                        break;
                    }
                }
                
                chunks_processed_since_feedback++;
            }
            
            // Lazy feedback: only update estimate every K chunks
            if(!found && chunks_processed_since_feedback >= feedback_freq){
                chunks_processed_since_feedback = 0;
            }
            
            // Request next batch (if not found)
            if(!found){
                // Non-blocking probe for stop signal
                int flag = 0;
                MPI_Iprobe(0, TAG_STOP, comm, &flag, &st);
                if(flag){
                    MPI_Recv(NULL, 0, MPI_BYTE, 0, TAG_STOP, comm, &st);
                    stop_received = 1;
                    break;
                }
                
                MPI_Send(&batch_size, 1, MPI_INT, 0, TAG_REQ, comm);
            }
        }
        
        MPI_Barrier(comm);
        
        double local_time = MPI_Wtime() - t_global0;
        
        MPI_Gather(&local_time, 1, MPI_DOUBLE, NULL, 0, MPI_DOUBLE, 0, comm);
        MPI_Gather(&local_tests, 1, MPI_UINT64_T, NULL, 0, MPI_UINT64_T, 0, comm);
    }
    
    // Cleanup
    free(cipher);
    free(needle);
    MPI_Finalize();
    return 0;
}
