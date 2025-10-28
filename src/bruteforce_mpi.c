//importacion de libs
#include "des_utils.h"
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>

// calcula llave efectiva des removiendo bits de paridad
static inline uint64_t des_effective_key(uint64_t k) {
    return k & ~0x0101010101010101ULL;
}

// convierte cadena a entero de 64 bits en base 16 o 10
static uint64_t parse_u64(const char *s) {
    if (s[0]=='0' && (s[1]=='x'||s[1]=='X')) return strtoull(s, NULL, 16);
    return strtoull(s, NULL, 10);
}

// imprime banner informativo del programa
static void banner(void) {
    puts("============================================================");
    puts("  BruteDES • MPI");
    puts("  - División equitativa del rango y early-stop");
    puts("============================================================\n");
}

// imprime uso del programa para ejecucion con mpi
static void usage0(const char *p) {
    banner();
    fprintf(stderr,
      "USO (MPI):\n"
    "  mpirun -np <P> %s -c <cipher.bin> -s \"substring\" [-L low] [-U up) [--no-stop]\n"
      "Ejemplo:\n"
      "  mpirun -np 4 %s -c data/cipher.bin -s \"es una prueba de\" -L 0 -U 72057594037927936\n",
      p, p);
}

int main(int argc, char **argv) {

    // parseo de argumentos y rangos por defecto
    const char *cipher_path=NULL, *needle=NULL;
    uint64_t L=0, U=(1ULL<<24);
    int no_stop = 0;

    for (int i=1; i<argc; ++i) {
        if (!strcmp(argv[i], "-c") && i+1<argc) cipher_path = argv[++i];
        else if (!strcmp(argv[i], "-s") && i+1<argc) needle = argv[++i];
        elsAe if (!strcmp(argv[i], "-L") && i+1<argc) L = parse_u64(argv[++i]);
        else if (!strcmp(argv[i], "-U") && i+1<argc) U = parse_u64(argv[++i]);
    else if (!strcmp(argv[i], "--no-stop")) no_stop = 1;
    else if (!strcmp(argv[i], "-h")) { usage0(argv[0]); return 0; }
    }
    // valida presencia de archivo cifrado y subcadena objetivo
    if (!cipher_path || !needle) { usage0(argv[0]); return 1; }

    // inicializa mpi y obtiene numero de procesos y rank
    MPI_Init(&argc, &argv);
    MPI_Comm comm = MPI_COMM_WORLD;
    int P=0, id=0;
    MPI_Comm_size(comm, &P);
    MPI_Comm_rank(comm, &id);

    if (id==0) banner();

    // lectura del archivo cifrado en rank cero y difusion a todos
    unsigned char *cipher=NULL; size_t clen=0;
    int nlen = (int)strlen(needle);

    if (id==0) {
        if (read_whole_file(cipher_path, &cipher, &clen) != 0) {
            fprintf(stderr, "[0] ERROR leyendo %s\n", cipher_path);
            MPI_Abort(comm, 2);
        }
    }

    // difunde longitud del cifrado y buffer a todos los procesos
    unsigned long long clen_ull = (id==0) ? (unsigned long long)clen : 0ULL;
    MPI_Bcast(&clen_ull, 1, MPI_UNSIGNED_LONG_LONG, 0, comm);
    clen = (size_t)clen_ull;

    if (id != 0) cipher = (unsigned char*)malloc(clen);
    MPI_Bcast(cipher, (int)clen, MPI_BYTE, 0, comm);

    // difunde longitud y contenido de la aguja a buscar
    MPI_Bcast(&nlen, 1, MPI_INT, 0, comm);
    char *needle_b = (char*)malloc(nlen+1);
    if (id==0) memcpy(needle_b, needle, nlen+1);
    MPI_Bcast(needle_b, nlen+1, MPI_CHAR, 0, comm);

    // divide el rango total en porciones equitativas por proceso
    uint64_t total = (U > L) ? (U - L) : 0;
    uint64_t per   = total / (uint64_t)P;
    uint64_t extra = total % (uint64_t)P;

    // calcula subrango asignado a este rank con reparto justo
    uint64_t uid = (uint64_t)id;
    uint64_t add = (uid < extra) ? uid : extra;
    uint64_t myL = L + per*uid + add;
    uint64_t myU = myL + per + (uid < extra);

    // prepara estado local y recepcion no bloqueante de llave encontrada
    uint64_t found = UINT64_MAX;
    uint64_t local_tests = 0;
    int status_code = 0; 
    int found_rank = -1;

    MPI_Request req = MPI_REQUEST_NULL; 
    MPI_Status st;
    const int allow_stop = !no_stop;
    if (allow_stop) {
        MPI_Irecv(&found, 1, MPI_UINT64_T, MPI_ANY_SOURCE, 777, comm, &req);
    }

    MPI_Barrier(comm);
    double t0 = MPI_Wtime();

    for (uint64_t k=myL; k<myU; ++k) {
        if (allow_stop) {
            int flag = 0;
            MPI_Test(&req, &flag, &st);
            if (flag) { status_code = 1; break; }
        }

        local_tests++;
        if (des_try_key(k, cipher, clen, needle_b)) {
            if (found == UINT64_MAX) {
                found = k;
                found_rank = id;
                status_code = 2;
            }
            if (allow_stop) {
                for (int p=0; p<P; ++p) {
                    MPI_Send(&found, 1, MPI_UINT64_T, p, 777, comm);
                }
                break;
            }
        }
    }

    MPI_Barrier(comm);
    double t1 = MPI_Wtime();
    double local_time = t1 - t0;

    if (allow_stop && req != MPI_REQUEST_NULL) {
        int completed = 0;
        MPI_Test(&req, &completed, &st);
        if (!completed) {
            MPI_Cancel(&req);
            MPI_Wait(&req, &st);
        }
    }

    if (!allow_stop && status_code == 0 && found != UINT64_MAX) {
        status_code = 2;
    }

    // reserva buffers en maestro para recopilar metricas globales
    double *times_all = NULL;
    uint64_t *tests_all = NULL, *L_all = NULL, *U_all = NULL;
    int *status_all = NULL, *rank_found_all = NULL;

    if (id==0) {
        times_all  = (double*)   malloc(sizeof(double)*P);
        tests_all  = (uint64_t*) malloc(sizeof(uint64_t)*P);
        L_all      = (uint64_t*) malloc(sizeof(uint64_t)*P);
        U_all      = (uint64_t*) malloc(sizeof(uint64_t)*P);
        status_all = (int*)      malloc(sizeof(int)*P);
        rank_found_all = (int*)  malloc(sizeof(int)*P);
    }

    // envia metricas locales al rank cero
    MPI_Gather(&local_time, 1, MPI_DOUBLE,   times_all, 1, MPI_DOUBLE,   0, comm);
    MPI_Gather(&local_tests,1, MPI_UINT64_T, tests_all, 1, MPI_UINT64_T, 0, comm);
    MPI_Gather(&myL,        1, MPI_UINT64_T, L_all,     1, MPI_UINT64_T, 0, comm);
    MPI_Gather(&myU,        1, MPI_UINT64_T, U_all,     1, MPI_UINT64_T, 0, comm);
    MPI_Gather(&status_code,1, MPI_INT,      status_all,1, MPI_INT,      0, comm);
    MPI_Gather(&found_rank, 1, MPI_INT,      rank_found_all,1, MPI_INT,  0, comm);

    // imprime resultados y resumen global en el rank cero
    double t_par_max = 0.0;
    MPI_Reduce(&local_time, &t_par_max, 1, MPI_DOUBLE, MPI_MAX, 0, comm);
    uint64_t found_global = UINT64_MAX;
    MPI_Reduce(&found, &found_global, 1, MPI_UINT64_T, MPI_MIN, 0, comm);

    if (id==0) {
    printf("→ BRUTEFORCE MPI\n");
        printf("  • Procesos : %d\n", P);
        printf("  • Archivo  : %s (bytes=%zu)\n", cipher_path, clen);
        printf("  • Subcadena: \"%s\"\n", needle_b);
        printf("  • Rango    : [%" PRIu64 ", %" PRIu64 ")\n", L, U);

        puts("\n  • Detalle por proceso");
        puts("    RANK |     START       END   |   TESTS    |  STATUS           |  TIME(s)");
        puts("    -----+-----------------------+------------+-------------------+---------");

        uint64_t sum_tests = 0;
        int who_found = -1;

        for (int r=0; r<P; ++r) {
            const char *stxt = (status_all[r]==2) ? "FOUND"
                               : (status_all[r]==1) ? "STOP(SIGNAL)"
                               : "DONE(RANGE)";
            printf("    %4d | %10" PRIu64 " %10" PRIu64 " | %10" PRIu64 " | %-17s | %7.4f\n",
                   r, L_all[r], U_all[r], tests_all[r], stxt, times_all[r]);
            sum_tests += tests_all[r];
            if (status_all[r]==2) who_found = r;
        }

        if (found_global != UINT64_MAX) {
            unsigned char *plain = (unsigned char*)malloc(clen+1);
            des_decrypt_buffer(found_global, cipher, clen, plain);
            plain[clen] = 0;

            uint64_t eff = des_effective_key(found_global);
            puts("\n  • Resultado: ✔ Llave encontrada");
            printf("    - Rank    : %d\n", (who_found>=0?who_found:rank_found_all[0]));
            printf("    - Llave   : %" PRIu64 " (efectiva dec=%" PRIu64 ", hex=0x%016" PRIx64 ")\n",
                   found_global, eff, eff);
            printf("    - Texto   : %s\n", plain);
            free(plain);
        } else {
            puts("\n  • Resultado: ✘ No encontrada.");
        }

        puts("\n  • Resumen global");
        printf("    - Llaves probadas totales  : %" PRIu64 "\n", sum_tests);
        printf("    - Tiempo total (max rank): %.6f s\n", t_par_max);
        puts("");
    }

    // libera memoria y cierra mpi
    free(cipher);
    free(needle_b);
    if (id==0) { free(times_all); free(tests_all); free(L_all); free(U_all); free(status_all); free(rank_found_all); }

    MPI_Finalize();
    return 0;
}
