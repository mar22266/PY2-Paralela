// importacion de librerias
#include "des_utils.h"
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>

// define tags de mensajes para maestro y workers
enum { TAG_REQ=100, TAG_TASK=101, TAG_STOP=102, TAG_FOUND=103 };

// convierte cadena a entero de 64 bits en hex o decimal
static uint64_t parse_u64(const char *s){ return (s[0]=='0'&&(s[1]=='x'||s[1]=='X'))? strtoull(s,NULL,16): strtoull(s,NULL,10); }
// devuelve el minimo entre dos enteros de 64 bits
static inline uint64_t min_u64(uint64_t a,uint64_t b){ return a<b?a:b; }
// elimina bits de paridad des para obtener llave efectiva
static inline uint64_t des_effective_key(uint64_t k){ return k & ~0x0101010101010101ULL; }

// imprime banner informativo del programa
static void banner(void){
    puts("============================================================");
    puts("  BruteDES • MPI (master–worker dinámico)");
    puts("  - Asignación por chunks, balance activo, early-stop");
    puts("============================================================\n");
}
// imprime instrucciones de uso en consola
static void usage(const char *p){
    banner();
    fprintf(stderr,"USO:\n  mpirun -np <P> %s -c <cipher.bin> -s \"substring\" [-L low] [-U up) [-B chunk]\n",p);
    fputs("  Opciones:\n", stderr);
    fputs("    --no-stop    No detiene al encontrar la llave (recorre todo el rango)\n", stderr);
}

int main(int argc,char**argv){
    // inicializa parametros de entrada y valores por defecto
    const char *cipher_path=NULL,*needle=NULL; uint64_t L=0,U=(1ULL<<24); uint64_t B=1000000ULL;
    int no_stop=0;
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"-c")&&i+1<argc) cipher_path=argv[++i];
        else if(!strcmp(argv[i],"-s")&&i+1<argc) needle=argv[++i];
        else if(!strcmp(argv[i],"-L")&&i+1<argc) L=parse_u64(argv[++i]);
        else if(!strcmp(argv[i],"-U")&&i+1<argc) U=parse_u64(argv[++i]);
        else if(!strcmp(argv[i],"-B")&&i+1<argc) B=parse_u64(argv[++i]);
        else if(!strcmp(argv[i],"--no-stop")) no_stop=1;
        else if(!strcmp(argv[i],"-h")){ usage(argv[0]); return 0; }
    }
    // valida que existan ruta de cifrado y subcadena
    if(!cipher_path||!needle){ usage(argv[0]); return 1; }

    // inicia mpi y obtiene cantidad de procesos y rank
    MPI_Init(&argc,&argv);
    MPI_Comm comm=MPI_COMM_WORLD; int P,id; MPI_Comm_size(comm,&P); MPI_Comm_rank(comm,&id);
    if(id==0) banner();

    // rank cero lee archivo cifrado y longitud de la aguja
    unsigned char *cipher=NULL; size_t clen=0; int nlen=0;
    if(id==0){ if(read_whole_file(cipher_path,&cipher,&clen)!=0){ fprintf(stderr,"ERROR leyendo %s\n",cipher_path); MPI_Abort(comm,2);} nlen=(int)strlen(needle); }
    // difunde longitud del cifrado a todos los procesos
    unsigned long long clen_ull=(id==0)?(unsigned long long)clen:0ULL;
    MPI_Bcast(&clen_ull,1,MPI_UNSIGNED_LONG_LONG,0,comm); clen=(size_t)clen_ull;
    // reserva memoria del cifrado en workers y difunde bytes
    if(id!=0) cipher=(unsigned char*)malloc(clen);
    MPI_Bcast(cipher,(int)clen,MPI_BYTE,0,comm);
    // difunde longitud y contenido de la aguja
    MPI_Bcast(&nlen,1,MPI_INT,0,comm);
    char *needle_b=(char*)malloc(nlen+1);
    if(id==0){ memcpy(needle_b,needle,nlen+1); }
    MPI_Bcast(needle_b,nlen+1,MPI_CHAR,0,comm);

    // difunde limites del rango y tamano de chunk
    MPI_Bcast(&L,1,MPI_UINT64_T,0,comm);
    MPI_Bcast(&U,1,MPI_UINT64_T,0,comm);
    MPI_Bcast(&B,1,MPI_UINT64_T,0,comm);

    // variables compartidas para resultado y rank ganador
    uint64_t found=UINT64_MAX; int who_found=-1;
    const int allow_stop=!no_stop;

    uint64_t local_tests = 0;    

    MPI_Barrier(comm);
    double t0=MPI_Wtime();

    // bloque maestro asigna chunks y maneja early stop
    if(id==0){
        uint64_t next=L;
        int active_workers=P-1;
        MPI_Status st;

        // bucle central del maestro para atender solicitudes y hallazgos
        while(active_workers>0){
            int flag=0; MPI_Iprobe(MPI_ANY_SOURCE,TAG_FOUND,comm,&flag,&st);
            if(flag){
                MPI_Recv(&found,1,MPI_UINT64_T,st.MPI_SOURCE,TAG_FOUND,comm,&st);
                if(who_found==-1) who_found=st.MPI_SOURCE;
                if(allow_stop){
                    for(int w=1; w<P; ++w){
                        int f2=0; MPI_Iprobe(w,TAG_REQ,comm,&f2,&st);
                        if(f2){
                            uint64_t junk; MPI_Recv(&junk,1,MPI_UINT64_T,w,TAG_REQ,comm,&st);
                        }
                        MPI_Send(&found,1,MPI_UINT64_T,w,TAG_STOP,comm);
                    }
                    break;
                }
            }
            MPI_Probe(MPI_ANY_SOURCE,TAG_REQ,comm,&st);
            int src=st.MPI_SOURCE; uint64_t dummy; MPI_Recv(&dummy,1,MPI_UINT64_T,src,TAG_REQ,comm,&st);
            if(found!=UINT64_MAX && allow_stop){ MPI_Send(&found,1,MPI_UINT64_T,src,TAG_STOP,comm); continue; }
            if(next>=U){ uint64_t msg=0; MPI_Send(&msg,1,MPI_UINT64_T,src,TAG_STOP,comm); active_workers--; continue; }
            uint64_t a=next, b=min_u64(next+B,U); next=b;
            uint64_t task[2]={a,b}; MPI_Send(task,2,MPI_UINT64_T,src,TAG_TASK,comm);
        }
        // envia señales de parada a todos los workers restantes
        for(int w=1; w<P; ++w){
            int f2=0; MPI_Iprobe(w,TAG_REQ,comm,&f2,&st);
            if(f2){ uint64_t d; MPI_Recv(&d,1,MPI_UINT64_T,w,TAG_REQ,comm,&st); }
            MPI_Send(&found,1,MPI_UINT64_T,w,TAG_STOP,comm);
        }
        // bloque worker solicita tareas y prueba llaves
    } else {
        MPI_Status st;
        for(;;){
            uint64_t req=1; MPI_Send(&req,1,MPI_UINT64_T,0,TAG_REQ,comm);
            MPI_Probe(0,MPI_ANY_TAG,comm,&st);
            if(st.MPI_TAG==TAG_TASK){
                uint64_t task[2]; MPI_Recv(task,2,MPI_UINT64_T,0,TAG_TASK,comm,&st);
                uint64_t a=task[0], b=task[1];
                for(uint64_t k=a;k<b;k++){
                    local_tests++;                              
                    if(des_try_key(k,cipher,clen,needle_b)){
                        if(found==UINT64_MAX){
                            found=k; MPI_Send(&found,1,MPI_UINT64_T,0,TAG_FOUND,comm);
                        }
                        if(allow_stop){ goto done; }
                    }
                    int flag=0; MPI_Iprobe(0,TAG_STOP,comm,&flag,&st);
                    if(flag){ MPI_Recv(&found,1,MPI_UINT64_T,0,TAG_STOP,comm,&st); goto done; }
                }
            } else if(st.MPI_TAG==TAG_STOP){
                MPI_Recv(&found,1,MPI_UINT64_T,0,TAG_STOP,comm,&st);
                break;
            }
        }
    done:
        ; 
    }

    MPI_Barrier(comm);
    double t1=MPI_Wtime();
    double local_time = t1 - t0;

    // recopila tiempos y tests en el maestro
    double *times_all=NULL; uint64_t *tests_all=NULL;
    if(id==0){ times_all=(double*)malloc(sizeof(double)*P); tests_all=(uint64_t*)malloc(sizeof(uint64_t)*P); }
    MPI_Gather(&local_time,1,MPI_DOUBLE,times_all,1,MPI_DOUBLE,0,comm);
    MPI_Gather(&local_tests,1,MPI_UINT64_T,tests_all,1,MPI_UINT64_T,0,comm);

    double t_par_max=0.0; MPI_Reduce(&local_time,&t_par_max,1,MPI_DOUBLE,MPI_MAX,0,comm);

    // maestro imprime resultados y desencripta si hubo hallazgo
    if(id==0){
        printf("→ BRUTEFORCE MPI (dinámico)\n");
        printf("  • Procesos : %d\n", P);
        printf("  • Chunk(B) : %" PRIu64 "\n", B);
        printf("  • Rango    : [%" PRIu64 ", %" PRIu64 ")\n", L, U);

        puts("\n  • Detalle por proceso");
        puts("    RANK |   TESTS     |  TIME(s)");
        puts("    -----+-------------+---------");
        uint64_t sum_tests = 0;
        for(int r=0;r<P;r++){ 
            printf("    %4d | %11" PRIu64 " | %7.4f\n", r, tests_all[r], times_all[r]);
            sum_tests += tests_all[r];
        }

        if(found!=UINT64_MAX){
            unsigned char *plain=(unsigned char*)malloc(clen+1);
            des_decrypt_buffer(found,cipher,clen,plain); plain[clen]=0;
            uint64_t eff=des_effective_key(found);
            puts("\n  • Resultado: ✔ Llave encontrada");
            printf("    - Rank    : %d\n", who_found);
            printf("    - Llave   : %" PRIu64 " (efectiva=%" PRIu64 ", 0x%016" PRIx64 ")\n", found, eff, eff);
            printf("    - Texto   : %s\n", plain);
            free(plain);
        } else {
            puts("\n  • Resultado: ✘ No encontrada");
        }

        puts("\n  • Resumen global");
        printf("    - Tiempo total (max rank): %.6f s\n", t_par_max);
        
        // Standardized metrics for pipeline parsing
        printf("rank_found: %d\n", (who_found>=0 ? who_found : -1));
        printf("tests_total: %" PRIu64 "\n", sum_tests);
        printf("Tiempo total (max rank): %.6f s\n", t_par_max);
        fflush(stdout);

        free(times_all); free(tests_all);
    }

    // libera buffers y finaliza mpi
    free(cipher); free(needle_b);
    MPI_Finalize(); return 0;
}
