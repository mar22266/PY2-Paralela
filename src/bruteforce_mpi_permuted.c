#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>
#include <string.h>

#include "des_utils.h" 

// tag para detener ejecucion temprana
#define STOP_TAG 777

// lee archivo binario completo en memoria y devuelve longitud
static int load_file(const char *path, unsigned char **buf, size_t *len){
    FILE *f = fopen(path, "rb");
    if(!f) return -1;
    if(fseek(f,0,SEEK_END)!=0){ fclose(f); return -1; }
    long n = ftell(f); if(n<0){ fclose(f); return -1; }
    rewind(f);
    *buf = (unsigned char*)malloc((size_t)n);
    if(!*buf){ fclose(f); return -1; }
    if(fread(*buf,1,(size_t)n,f)!=(size_t)n){ fclose(f); free(*buf); return -1; }
    fclose(f);
    *len = (size_t)n;
    return 0;
}

// busca subcadena de bytes dentro de un buffer
static const unsigned char* u8memmem(const unsigned char *h, size_t n, const unsigned char *ndl, size_t m){
    if(!h || !ndl || m==0 || n<m) return NULL;
    for(size_t i=0;i<=n-m;i++){
        if(h[i]==ndl[0] && memcmp(h+i,ndl,m)==0) return h+i;
    }
    return NULL;
}

// calcula mcd de dos enteros de 64 bits
static uint64_t gcd_u64(uint64_t a, uint64_t b){ while(b){ uint64_t t=a%b; a=b; b=t; } return a; }

int main(int argc, char **argv){
    // inicia mpi y obtiene total de procesos y rank local
    MPI_Init(&argc,&argv);
    MPI_Comm comm = MPI_COMM_WORLD;
    int P=1,id=0; MPI_Comm_size(comm,&P); MPI_Comm_rank(comm,&id);

    // variables de entrada y rango de llaves
    const char *cpath=NULL, *needle_cli=NULL;
    uint64_t L=0, U=(1ULL<<24), seed=0;

    // parsea argumentos y establece valores por defecto
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"-c") && i+1<argc) cpath=argv[++i];
        else if(!strcmp(argv[i],"-s") && i+1<argc) needle_cli=argv[++i];
        else if(!strcmp(argv[i],"-L") && i+1<argc) L=strtoull(argv[++i],NULL,10);
        else if(!strcmp(argv[i],"-U") && i+1<argc) U=strtoull(argv[++i],NULL,10);
        else if(!strcmp(argv[i],"-R") && i+1<argc) seed=strtoull(argv[++i],NULL,10);
    }
    // valida argumentos obligatorios y rango valido
    if(!cpath || !needle_cli || U<=L){
        if(id==0){
            fprintf(stderr,
                "USO:\n"
                "  mpirun -np <P> %s -c <cipher.bin> -s \"substring\" [-L low] [-U up) [-R seed]\n",
                argv[0]);
        }
        MPI_Finalize(); return 1;
    }

    // rank cero lee cifrado y valida longitud multiplo de ocho
    unsigned char *cipher=NULL; size_t clen_sz=0;
    if(id==0){
        if(load_file(cpath,&cipher,&clen_sz)!=0){
            fprintf(stderr,"No pude leer %s\n", cpath);
            MPI_Abort(comm,2);
        }
        if(clen_sz==0 || (clen_sz%8)!=0){
            fprintf(stderr,"El cifrado debe ser >0 y múltiplo de 8 bytes (DES-ECB)\n");
            MPI_Abort(comm,3);
        }
    }
    // difunde longitud del cifrado y buffer a todos los procesos
    uint64_t clen64 = (id==0)? (uint64_t)clen_sz : 0;
    MPI_Bcast(&clen64,1,MPI_UINT64_T,0,comm);
    if(id!=0){
        clen_sz=(size_t)clen64;
        cipher=(unsigned char*)malloc(clen_sz);
        if(!cipher){ fprintf(stderr,"Rank %d: malloc cipher\n", id); MPI_Abort(comm,4); }
    }
    MPI_Bcast(cipher,(int)clen_sz,MPI_UNSIGNED_CHAR,0,comm);

    // difunde longitud y contenido de la cadena a buscar
    int nlen=0; if(id==0) nlen=(int)strlen(needle_cli);
    MPI_Bcast(&nlen,1,MPI_INT,0,comm);
    unsigned char *needle=(unsigned char*)malloc((size_t)nlen+1);
    if(!needle){ fprintf(stderr,"Rank %d: malloc needle\n", id); MPI_Abort(comm,5); }
    if(id==0) memcpy(needle, needle_cli, (size_t)nlen+1);
    MPI_Bcast(needle, nlen+1, MPI_UNSIGNED_CHAR, 0, comm);

    // imprime banner con configuracion inicial en rank cero
    if(id==0){
        printf("============================================================\n");
        printf("  BruteDES • MPI (permuted-stride)\n");
        printf("  - Permutación lineal (LCG) por stride para barajar llaves\n");
        printf("============================================================\n\n");
        printf("→ BRUTEFORCE MPI (permuted)\n");
        printf("  • Procesos : %d\n", P);
        printf("  • Archivo  : %s (bytes=%zu)\n", cpath, clen_sz);
        printf("  • Subcadena: \"%s\"\n", (char*)needle);
        printf("  • Rango    : [%" PRIu64 ", %" PRIu64 ")\n\n", L, U);
        fflush(stdout);
    }

    // calcula tamano del espacio de busqueda
    const uint64_t N = U - L;
    if(N==0){ if(id==0) fprintf(stderr,"Rango vacío\n"); MPI_Finalize(); return 0; }

    // elige parametro a coprimo con n para lcg
    uint64_t A = 6364136223846793005ULL | 1ULL; 
    while(gcd_u64(A,N)!=1) A+=2ULL;           
    uint64_t B = seed ^ (0x9E3779B97F4A7C15ULL*(uint64_t)id);

    // prepara recepcion no bloqueante de senal de stop
    MPI_Request reqStop;
    MPI_Irecv(NULL, 0, MPI_BYTE, MPI_ANY_SOURCE, STOP_TAG, comm, &reqStop);
    int stop_flag = 0;
    MPI_Status st_ignore;

    // reserva buffer para texto plano
    unsigned char *plain=(unsigned char*)malloc(clen_sz);
    if(!plain){ fprintf(stderr,"Rank %d: malloc plain\n", id); MPI_Abort(comm,6); }

    // fija frecuencia de chequeo de stop y contadores locales
    const int CHECK_EVERY = 4096;
    uint64_t mytests=0;
    int found_local=0;
    uint64_t found_key=0;

    // sincroniza procesos y toma tiempo inicial
    MPI_Barrier(comm);
    double t0 = MPI_Wtime();

    // bucle de prueba con indices intercalados y permutados
    for(uint64_t t=0; ; ++t){
        if((t % CHECK_EVERY)==0){
            MPI_Test(&reqStop, &stop_flag, &st_ignore);
            if(stop_flag) break;
        }
        uint64_t i = (uint64_t)id + t*(uint64_t)P;
        if(i>=N) break;

        // aplica permutacion lineal al indice
        uint64_t idx = (A*i + B) % N;
        // deriva llave dentro del rango
        uint64_t k = L + idx;

        // desencripta con la llave candidata y busca la subcadena
        des_decrypt_buffer(k, cipher, clen_sz, plain); 
        mytests++;
        if(u8memmem(plain,clen_sz,needle,(size_t)nlen)){
            found_local=1; found_key=k;
            // envia stop a todos los demas procesos
            for(int r=0;r<P;r++){
                if(r==id) continue;
                MPI_Send(NULL,0,MPI_BYTE,r,STOP_TAG,comm);
            }
            break;
        }
    }

    // cancela recepcion de stop si no fue usada
    if(!stop_flag){
        MPI_Cancel(&reqStop);
        MPI_Request_free(&reqStop);
    }

     // calcula tiempo
    double mytime = MPI_Wtime()-t0;

    // reserva arreglos en maestro y recolecta metricas
    int *found_flags=NULL; double *times=NULL; uint64_t *tests=NULL; uint64_t *keys=NULL;
    if(id==0){
        found_flags=(int*)calloc((size_t)P,sizeof(int));
        times      =(double*)calloc((size_t)P,sizeof(double));
        tests      =(uint64_t*)calloc((size_t)P,sizeof(uint64_t));
        keys       =(uint64_t*)calloc((size_t)P,sizeof(uint64_t));
        if(!found_flags||!times||!tests||!keys){ fprintf(stderr,"Root alloc\n"); MPI_Abort(comm,7); }
    }
    MPI_Gather(&found_local,1,MPI_INT,      found_flags,1,MPI_INT,      0,comm);
    MPI_Gather(&mytime,     1,MPI_DOUBLE,   times,      1,MPI_DOUBLE,   0,comm);
    MPI_Gather(&mytests,    1,MPI_UINT64_T, tests,      1,MPI_UINT64_T, 0,comm);
    MPI_Gather(&found_key,  1,MPI_UINT64_T, keys,       1,MPI_UINT64_T, 0,comm);

    // determina proceso ganador y difunde llave encontrada
    int winner=-1; uint64_t k_bcast=0;
    if(id==0){
        for(int r=0;r<P;r++){
            if(found_flags[r]){
                if(winner==-1 || times[r]<times[winner]) winner=r;
            }
        }
        if(winner>=0) k_bcast=keys[winner];
    }
    MPI_Bcast(&winner, 1, MPI_INT,      0, comm);
    MPI_Bcast(&k_bcast,1, MPI_UINT64_T, 0, comm);

     // calcula tiempo total como maximo entre procesos
    double tmax=0.0; MPI_Allreduce(&mytime,&tmax,1,MPI_DOUBLE,MPI_MAX,comm);

    // imprime tabla de procesos y resultado global
    if(id==0){
        printf("  • Detalle por proceso\n");
        printf("    RANK |   TESTS     |  STATUS           |  TIME(s)\n");
        printf("    -----+-------------+-------------------+---------\n");
        for(int r=0;r<P;r++){
            const char *status_str = (found_flags[r] ? "FOUND" : (winner>=0 ? "STOP(SIGNAL)" : "DONE"));
            printf(" %5d | %11" PRIu64 " | %-17s | %7.4f%s\n",
                   r, tests[r], status_str, times[r], (r==winner? "  <==":""));
        }
        printf("\n  • Resultado: %s\n", (winner>=0? "✔ Llave encontrada":"✘ No encontrada"));
        if(winner>=0){
            printf("    - Rank    : %d\n", winner);
            printf("    - Llave   : %" PRIu64 "\n", k_bcast);
            unsigned char *plain2=(unsigned char*)malloc(clen_sz+1);
            if(plain2){
                des_decrypt_buffer(k_bcast, cipher, clen_sz, plain2);
                plain2[clen_sz]=0;
                printf("    - Texto   : %.*s\n", (int)clen_sz, (char*)plain2);
                free(plain2);
            }
        }
        printf("\n  • Resumen global\n");
        printf("    - Tiempo total (max rank)  : %.6f s\n\n", tmax);
        fflush(stdout);

        free(found_flags); free(times); free(tests); free(keys);
    }

    // libera memoria y finaliza mpi
    free(plain); free(needle); free(cipher);
    MPI_Finalize();
    return 0;
}
