#include "des_utils.h"
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>

static uint64_t parse_u64(const char *s){ return (s[0]=='0'&&(s[1]=='x'||s[1]=='X'))? strtoull(s,NULL,16): strtoull(s,NULL,10); }
static inline uint64_t des_effective_key(uint64_t k){ return k & ~0x0101010101010101ULL; }

static void banner(void){
    puts("============================================================");
    puts("  BruteDES • MPI (cíclico/strided)");
    puts("  - Llaves intercaladas: k = L + rank + t*P");
    puts("  - Early-stop no bloqueante");
    puts("============================================================\n");
}
static void usage(const char *p){
    banner();
    fprintf(stderr, "USO:\n  mpirun -np <P> %s -c <cipher.bin> -s \"substring\" [-L low] [-U up)\n", p);
}

int main(int argc,char**argv){
    const char *cipher_path=NULL,*needle=NULL; uint64_t L=0,U=(1ULL<<24);
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"-c")&&i+1<argc) cipher_path=argv[++i];
        else if(!strcmp(argv[i],"-s")&&i+1<argc) needle=argv[++i];
        else if(!strcmp(argv[i],"-L")&&i+1<argc) L=parse_u64(argv[++i]);
        else if(!strcmp(argv[i],"-U")&&i+1<argc) U=parse_u64(argv[++i]);
        else if(!strcmp(argv[i],"-h")){ usage(argv[0]); return 0; }
    }
    if(!cipher_path||!needle){ usage(argv[0]); return 1; }

    MPI_Init(&argc,&argv);
    MPI_Comm comm=MPI_COMM_WORLD; int P,id; MPI_Comm_size(comm,&P); MPI_Comm_rank(comm,&id);
    if(id==0) banner();

    unsigned char *cipher=NULL; size_t clen=0; int nlen=(int)strlen(needle);
    if(id==0){
        if(read_whole_file(cipher_path,&cipher,&clen)!=0){
            fprintf(stderr,"ERROR leyendo %s\n",cipher_path); MPI_Abort(comm,2);
        }
    }
    unsigned long long clen_ull=(id==0)?(unsigned long long)clen:0ULL;
    MPI_Bcast(&clen_ull,1,MPI_UNSIGNED_LONG_LONG,0,comm); clen=(size_t)clen_ull;
    if(id!=0) cipher=(unsigned char*)malloc(clen);
    MPI_Bcast(cipher,(int)clen,MPI_BYTE,0,comm);

    MPI_Bcast(&nlen,1,MPI_INT,0,comm);
    char *needle_b=(char*)malloc(nlen+1);
    if(id==0){
        memcpy(needle_b,needle,nlen+1);
    }
    MPI_Bcast(needle_b,nlen+1,MPI_CHAR,0,comm);

    uint64_t found=UINT64_MAX, local_tests=0; int status_code=0, found_rank=-1;
    MPI_Request req; MPI_Status st; MPI_Irecv(&found,1,MPI_UINT64_T,MPI_ANY_SOURCE,777,comm,&req);

    double t0=MPI_Wtime();
    for(uint64_t k=L+(uint64_t)id; k<U; k+=(uint64_t)P){
        int flag=0; MPI_Test(&req,&flag,&st); if(flag){ status_code=1; break; }
        local_tests++;
        if(des_try_key(k,cipher,clen,needle_b)){
            found=k; status_code=2; found_rank=id;
            for(int p=0;p<P;p++) MPI_Send(&found,1,MPI_UINT64_T,p,777,comm);
            break;
        }
    }
    double t1=MPI_Wtime(), local_time=t1-t0;
    int completed=0; MPI_Test(&req,&completed,&st); if(!completed){ MPI_Cancel(&req); MPI_Wait(&req,&st); }

    double *times_all=NULL; uint64_t *tests_all=NULL; int *status_all=NULL,*rf_all=NULL;
    if(id==0){ times_all=(double*)malloc(sizeof(double)*P); tests_all=(uint64_t*)malloc(sizeof(uint64_t)*P);
               status_all=(int*)malloc(sizeof(int)*P); rf_all=(int*)malloc(sizeof(int)*P); }
    MPI_Gather(&local_time,1,MPI_DOUBLE,times_all,1,MPI_DOUBLE,0,comm);
    MPI_Gather(&local_tests,1,MPI_UINT64_T,tests_all,1,MPI_UINT64_T,0,comm);
    MPI_Gather(&status_code,1,MPI_INT,status_all,1,MPI_INT,0,comm);
    MPI_Gather(&found_rank,1,MPI_INT,rf_all,1,MPI_INT,0,comm);

    if(id==0){
        printf("→ BRUTEFORCE MPI (cíclico)\n  • Procesos : %d\n  • Archivo  : %s (bytes=%zu)\n  • Subcadena: \"%s\"\n  • Rango    : [%" PRIu64 ", %" PRIu64 ")\n",
               P,cipher_path,clen,needle_b,L,U);
        puts("\n  • Detalle por proceso");
        puts("    RANK |   TESTS    |  STATUS           |  TIME(s)");
        puts("    -----+------------+-------------------+---------");
        uint64_t sum=0; double tmax=0; int who=-1;
        for(int r=0;r<P;r++){
            const char* stxt=(status_all[r]==2)?"FOUND":(status_all[r]==1)?"STOP(SIGNAL)":"DONE(RANGE)";
            printf("    %4d | %10" PRIu64 " | %-17s | %7.4f\n",r,tests_all[r],stxt,times_all[r]);
            sum+=tests_all[r]; if(times_all[r]>tmax) tmax=times_all[r]; if(status_all[r]==2) who=r;
        }
        if(found!=UINT64_MAX){
            unsigned char *plain=(unsigned char*)malloc(clen+1); des_decrypt_buffer(found,cipher,clen,plain); plain[clen]=0;
            uint64_t eff=des_effective_key(found);
            puts("\n  • Resultado: ✔ Llave encontrada");
            printf("    - Rank    : %d\n", (who>=0?who:rf_all[0]));
            printf("    - Llave   : %" PRIu64 " (efectiva=%" PRIu64 ", 0x%016" PRIx64 ")\n", found, eff, eff);
            printf("    - Texto   : %s\n", plain); free(plain);
        } else puts("\n  • Resultado: ✘ No encontrada");
        puts("\n  • Resumen global"); printf("    - Llaves probadas totales  : %" PRIu64 "\n", sum); printf("    - Tiempo total (max rank)  : %.6f s\n", tmax);
        free(times_all); free(tests_all); free(status_all); free(rf_all);
    }
    free(cipher); free(needle_b); MPI_Barrier(comm); MPI_Finalize(); return 0;
}
