// importaicon de libs
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>
#include <string.h>

#include "des_utils.h"

// tags de mensajes para maestro y workers
enum { TAG_REQ=1, TAG_TASK=2, TAG_FOUND=3, TAG_STOP=4 };

// lee archivo binario completo en memoria y devuelve longitud
static int load_file(const char *path, unsigned char **buf, size_t *len){
    FILE *f=fopen(path,"rb");
    if(!f) return -1;
    if(fseek(f,0,SEEK_END)!=0){ fclose(f); return -1; }
    long n=ftell(f); if(n<0){ fclose(f); return -1; }
    rewind(f);
    *buf=(unsigned char*)malloc((size_t)n);
    if(!*buf){ fclose(f); return -1; }
    if(fread(*buf,1,(size_t)n,f)!=(size_t)n){ fclose(f); free(*buf); return -1; }
    fclose(f); *len=(size_t)n; return 0;
}

// busca subcadena de bytes dentro de un buffer
static const unsigned char* u8memmem(const unsigned char *h, size_t n, const unsigned char *ndl, size_t m){
    if(!h || !ndl || m==0 || n<m) return NULL;
    for(size_t i=0;i<=n-m;i++){
        if(h[i]==ndl[0] && memcmp(h+i,ndl,m)==0) return h+i;
    }
    return NULL;
}

int main(int argc, char **argv){
    // inicia mpi y obtiene tamano y rango
    MPI_Init(&argc,&argv);
    MPI_Comm comm=MPI_COMM_WORLD;
    int P=1,id=0; MPI_Comm_size(comm,&P); MPI_Comm_rank(comm,&id);
    if(P<2){ if(id==0) fprintf(stderr,"Se requieren al menos 2 procesos (1 maestro + workers)\n"); MPI_Finalize(); return 1; }

    // parsea argumentos de linea y valores por defecto
    const char *cpath=NULL,*needle_cli=NULL;
    uint64_t L=0,U=(1ULL<<24);
    double target_ms=30.0;

    // ciclo de parseo de flags
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"-c") && i+1<argc) cpath=argv[++i];
        else if(!strcmp(argv[i],"-s") && i+1<argc) needle_cli=argv[++i];
        else if(!strcmp(argv[i],"-L") && i+1<argc) L=strtoull(argv[++i],NULL,10);
        else if(!strcmp(argv[i],"-U") && i+1<argc) U=strtoull(argv[++i],NULL,10);
        else if(!strcmp(argv[i],"-T") && i+1<argc) target_ms=strtod(argv[++i],NULL);
    }
    if(!cpath||!needle_cli||U<=L){
        if(id==0) fprintf(stderr,"USO:\n  mpirun -np <P> %s -c <cipher.bin> -s \"substring\" [-L low] [-U up) [-T target_ms]\n",argv[0]);
        MPI_Finalize(); return 2;
    }

    // rank cero lee cifrado y valida multiplo de ocho
    unsigned char *cipher=NULL; size_t clen_sz=0;
    if(id==0){
        if(load_file(cpath,&cipher,&clen_sz)!=0){ fprintf(stderr,"No pude leer %s\n",cpath); MPI_Abort(comm,3); }
        if(clen_sz==0 || (clen_sz%8)!=0){ fprintf(stderr,"El cifrado debe ser >0 y múltiplo de 8 bytes\n"); MPI_Abort(comm,4); }
    }
    // difunde longitud del cifrado a todos
    uint64_t clen64=(id==0)?(uint64_t)clen_sz:0;
    MPI_Bcast(&clen64,1,MPI_UINT64_T,0,comm);
    // workers reservan buffer para el cifrado
    if(id!=0){
        clen_sz=(size_t)clen64;
        cipher=(unsigned char*)malloc(clen_sz);
        if(!cipher){ fprintf(stderr,"Rank %d: malloc cipher\n",id); MPI_Abort(comm,5); }
    }
    MPI_Bcast(cipher,(int)clen_sz,MPI_UNSIGNED_CHAR,0,comm);

    // difunde longitud y contenido de la aguja
    int nlen=0; if(id==0) nlen=(int)strlen(needle_cli);
    MPI_Bcast(&nlen,1,MPI_INT,0,comm);
    unsigned char *needle=(unsigned char*)malloc((size_t)nlen+1);
    if(!needle){ fprintf(stderr,"Rank %d: malloc needle\n",id); MPI_Abort(comm,6); }
    if(id==0) memcpy(needle,needle_cli,(size_t)nlen+1);
    MPI_Bcast(needle,nlen+1,MPI_UNSIGNED_CHAR,0,comm);

    // banner inicial y datos de ejecucion
    if(id==0){
        printf("============================================================\n");
        printf("  BruteDES • MPI (dinámico adaptativo)\n");
        printf("  - Maestro estima throughput y ajusta chunk a %.2f ms\n", target_ms);
        printf("============================================================\n\n");
        printf("→ BRUTEFORCE MPI (dynamic-adaptive)\n");
    }

    // sincroniza procesos y toma tiempo global inicial
    MPI_Barrier(comm);
    double t_global0=MPI_Wtime();

    // maestro muestra configuracion basica
    if(id==0){
        printf("  • Procesos : %d (1 maestro + %d workers)\n", P, P-1);
        printf("  • Rango    : [%" PRIu64 ", %" PRIu64 ")\n\n", L, U);
        fflush(stdout);
    }

    // bloque del maestro con planificador dinamico
    if(id==0){
        // inicializa punteros del rango de llaves
        uint64_t next=L, end=U;

        // arreglos por worker para tiempos throughput y tamanos de chunk
        double last_send_t[1024]; for(int i=0;i<1024;i++) last_send_t[i]=0.0;
        double thr_keys_s[1024];  for(int i=0;i<1024;i++) thr_keys_s[i]=300000.0;
        uint64_t cur_B[1024];     for(int i=0;i<1024;i++) cur_B[i]=20000;

        // estado de hallazgo y llave ganadora
        int any_found=0, winner=-1; uint64_t found_key=0;
        MPI_Status st;

        // atiende primer pedido de cada worker y envia tarea inicial
        for(int w=1; w<P; ++w){
            int dummy; MPI_Recv(&dummy,1,MPI_INT,w,TAG_REQ,comm,&st);
            uint64_t B = cur_B[w];
            uint64_t task[2] = { next, (next+B<end? next+B : end) };
            if(task[0]<task[1]) next = task[1]; else task[0]=task[1]=end;
            MPI_Send(task,2,MPI_UINT64_T,w,TAG_TASK,comm);
            last_send_t[w]=MPI_Wtime();
        }

        // bucle principal del maestro para asignar tareas y escuchar eventos
        while(!any_found){
            MPI_Probe(MPI_ANY_SOURCE, MPI_ANY_TAG, comm, &st);
            int src=st.MPI_SOURCE, tag=st.MPI_TAG;

            // recibe llave encontrada y envia stop a todos
            if(tag==TAG_FOUND){
                uint64_t k; MPI_Recv(&k,1,MPI_UINT64_T,src,TAG_FOUND,comm,&st);
                any_found=1; winner=src; found_key=k;
                for(int w=1; w<P; ++w){ MPI_Send(NULL,0,MPI_BYTE,w,TAG_STOP,comm); }
                break;

            // ajusta chunk con ema segun throughput y envia nueva tarea
            } else if(tag==TAG_REQ){
                int dummy; MPI_Recv(&dummy,1,MPI_INT,src,TAG_REQ,comm,&st);

                double now = MPI_Wtime();
                double dt  = now - last_send_t[src];
                double keys= (double)cur_B[src];
                if(dt>0.0 && keys>0.0){
                    double thr = keys/dt;
                    thr_keys_s[src] = 0.5*thr_keys_s[src] + 0.5*thr; // EMA
                }

                double target_s = (target_ms>0.0? target_ms/1000.0 : 0.03);
                uint64_t Bmin=2000, Bmax=200000;
                uint64_t B = (uint64_t)(thr_keys_s[src]*target_s);
                if(B<Bmin) B=Bmin; if(B>Bmax) B=Bmax;

                uint64_t task[2];
                if(next>=end){ task[0]=end; task[1]=end; }
                else { task[0]=next; task[1]=(next+B<end? next+B : end); next=task[1]; }
                cur_B[src] = (task[1]>task[0])? (task[1]-task[0]) : 0;
                last_send_t[src]=now;

                MPI_Send(task,2,MPI_UINT64_T,src,TAG_TASK,comm);

            } else {
                MPI_Abort(comm, 99);
            }
        }

        // calcula tiempo del maestro y prepara metricas 
        double t_global1=MPI_Wtime();
        double mytime_master = t_global1 - t_global0;
        uint64_t mytests_master = 0;
        int st_master = 0;           

        double   *times  = (double*)  calloc((size_t)P,sizeof(double));
        uint64_t *tests  = (uint64_t*)calloc((size_t)P,sizeof(uint64_t));
        int      *status = (int*)     calloc((size_t)P,sizeof(int));
        if(!times||!tests||!status){ fprintf(stderr,"Root: alloc metrics\n"); MPI_Abort(comm,77); }

        // recolecta tiempos pruebas y estados
        MPI_Gather(&mytime_master, 1, MPI_DOUBLE,   times,  1, MPI_DOUBLE,   0, comm);
        MPI_Gather(&mytests_master,1, MPI_UINT64_T, tests,  1, MPI_UINT64_T, 0, comm);
        MPI_Gather(&st_master,     1, MPI_INT,      status, 1, MPI_INT,      0, comm);

        // imprime tabla de procesos y marca al ganador
        printf("  • Detalle por proceso\n");
        printf("    RANK |   TESTS     |  STATUS           |  TIME(s)\n");
        printf("    -----+-------------+-------------------+---------\n");
        for(int r=0;r<P;r++){
            const char *status_str = (r==0 ? "MASTER" : (status[r]==2 ? "FOUND" : "STOP(SIGNAL)"));
            printf(" %5d | %11" PRIu64 " | %-17s | %7.4f%s\n",
                   r, tests[r], status_str, times[r], (r==winner? "  <==":""));
        }

        // muestra resultado y desencripta si se encontro llave
        printf("\n  • Resultado: %s\n", (winner>=1? "✔ Llave encontrada":"✘ No encontrada"));
        if(winner>=1){
            printf("    - Rank    : %d\n", winner);
            printf("    - Llave   : %" PRIu64 "\n", found_key);
            unsigned char *plain=(unsigned char*)malloc(clen_sz+1);
            if(plain){
                des_decrypt_buffer(found_key, cipher, clen_sz, plain);
                plain[clen_sz]=0;
                printf("    - Texto   : %.*s\n", (int)clen_sz, (char*)plain);
                free(plain);
            }
        }

        // calcula tiempo total tomando el maximo entre ranks
        double tmax=0.0; for(int r=0;r<P;r++) if(times[r]>tmax) tmax=times[r];
        printf("\n  • Resumen global\n");
        printf("    - Tiempo total (max rank)  : %.6f s\n\n", tmax);
        fflush(stdout);

        // libera arreglos de metricas
        free(times); free(tests); free(status);

         // bloque del worker
    } else {
        unsigned char *plain=(unsigned char*)malloc(clen_sz);
        if(!plain){ fprintf(stderr,"Rank %d: malloc plain\n", id); MPI_Abort(comm,7); }

        uint64_t mytests=0;
        int req=1; MPI_Send(&req,1,MPI_INT,0,TAG_REQ,comm);
        double t0=MPI_Wtime();

        int found_local=0;

        while(1){
            MPI_Status stw;
            MPI_Probe(0, MPI_ANY_TAG, comm, &stw);
            // recibe orden de detenerse
            if(stw.MPI_TAG==TAG_STOP){
                MPI_Recv(NULL,0,MPI_BYTE,0,TAG_STOP,comm,&stw);
                break;
                 // recibe rango de trabajo
            } else if(stw.MPI_TAG==TAG_TASK){
                uint64_t task[2]; MPI_Recv(task,2,MPI_UINT64_T,0,TAG_TASK,comm,&stw);
                uint64_t a=task[0], b=task[1];
                if(a>=b){ break; }
                for(uint64_t k=a;k<b;++k){
                    des_decrypt_buffer(k, cipher, clen_sz, plain);
                    mytests++;
                    if(u8memmem(plain,clen_sz,needle,(size_t)nlen)){
                        found_local=1;
                        MPI_Send(&k,1,MPI_UINT64_T,0,TAG_FOUND,comm);
                        goto fin_worker;
                    }
                }
                MPI_Send(&req,1,MPI_INT,0,TAG_REQ,comm);
            }
        }
fin_worker:
        {
            // envia tiempo pruebas y estado al maestro
            double mytime = MPI_Wtime()-t0;
            int st_code = found_local ? 2 : 1 ;

            MPI_Gather(&mytime,  1, MPI_DOUBLE,   NULL, 0, MPI_DOUBLE,   0, comm);
            MPI_Gather(&mytests, 1, MPI_UINT64_T, NULL, 0, MPI_UINT64_T, 0, comm);
            MPI_Gather(&st_code, 1, MPI_INT,      NULL, 0, MPI_INT,      0, comm);
        }
        free(plain);
    }

    // libera buffers y finaliza mpi
    free(needle); free(cipher);
    MPI_Finalize();
    return 0;
}
