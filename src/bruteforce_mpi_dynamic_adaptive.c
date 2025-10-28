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
    int no_stop=0;
    // banner inicial y datos de ejecucion
    if(id==0){
        printf("============================================================\n");
        printf("  BruteDES • MPI (dinámico adaptativo)\n");
        printf("  - Maestro estima throughput y ajusta chunk a %.2f ms\n", target_ms);
        printf("============================================================\n\n");
        printf("→ BRUTEFORCE MPI (dynamic-adaptive)\n");
        printf("  • Procesos : %d (1 maestro + %d workers)\n", P, P-1);
        printf("  • Rango    : [" PRIu64 ", " PRIu64 ")\n\n", L, U);
        fflush(stdout);
    }

    uint64_t local_tests=0;
    int status_code=(id==0)?0:1;
    uint64_t found_key=UINT64_MAX;
    int winner=-1;

    MPI_Barrier(comm);
    double t0=MPI_Wtime();

    if(id==0){
        const uint64_t end=U;
        uint64_t next=L;

        double *last_send_t=(double*)calloc((size_t)P,sizeof(double));
        double *thr_keys_s=(double*)calloc((size_t)P,sizeof(double));
        uint64_t *cur_B=(uint64_t*)calloc((size_t)P,sizeof(uint64_t));
        if(!last_send_t||!thr_keys_s||!cur_B){ fprintf(stderr,"Root: memoria planificador\n"); MPI_Abort(comm,77); }
        for(int w=0; w<P; ++w){
            thr_keys_s[w]=300000.0;
            cur_B[w]=20000;
        }

        MPI_Status st;
        for(int w=1; w<P; ++w){
            int dummy; MPI_Recv(&dummy,1,MPI_INT,w,TAG_REQ,comm,&st);
            uint64_t B=cur_B[w];
            uint64_t task[2]={ next, (next+B<end? next+B:end) };
            if(task[0]<task[1]) next=task[1]; else task[0]=task[1]=end;
            cur_B[w]=(task[1]>task[0])? (task[1]-task[0]) : 0;
            MPI_Send(task,2,MPI_UINT64_T,w,TAG_TASK,comm);
            last_send_t[w]=MPI_Wtime();
        }

        int running_workers=P-1;
        while(running_workers>0){
            MPI_Probe(MPI_ANY_SOURCE,MPI_ANY_TAG,comm,&st);
            int src=st.MPI_SOURCE;
            if(st.MPI_TAG==TAG_FOUND){
                uint64_t k; MPI_Recv(&k,1,MPI_UINT64_T,src,TAG_FOUND,comm,&st);
                if(winner==-1){ winner=src; found_key=k; }
                if(allow_stop){
                    for(int w=1; w<P; ++w){
                        MPI_Status st_req;
                        int has_req=0; MPI_Iprobe(w,TAG_REQ,comm,&has_req,&st_req);
                        if(has_req){ int junk; MPI_Recv(&junk,1,MPI_INT,w,TAG_REQ,comm,&st_req); }
                        MPI_Send(NULL,0,MPI_BYTE,w,TAG_STOP,comm);
                    }
                    running_workers=0;
                    break;
                }
            } else if(st.MPI_TAG==TAG_REQ){
                int dummy; MPI_Recv(&dummy,1,MPI_INT,src,TAG_REQ,comm,&st);

                if(allow_stop && winner!=-1){
                    MPI_Send(NULL,0,MPI_BYTE,src,TAG_STOP,comm);
                    running_workers--;
                    continue;
                }

                double now=MPI_Wtime();
                double dt=now-last_send_t[src];
                double keys=(double)cur_B[src];
                if(dt>0.0 && keys>0.0){
                    double thr=keys/dt;
                    thr_keys_s[src]=0.5*thr_keys_s[src]+0.5*thr;
                }

                double target_s=(target_ms>0.0? target_ms/1000.0 : 0.03);
                uint64_t Bmin=2000,Bmax=200000;
                uint64_t B=(uint64_t)(thr_keys_s[src]*target_s);
                if(B<Bmin) B=Bmin;
                if(B>Bmax) B=Bmax;

                if(next>=end){
                    MPI_Send(NULL,0,MPI_BYTE,src,TAG_STOP,comm);
                    running_workers--;
                    continue;
                }

                uint64_t task[2];
                task[0]=next;
                uint64_t up=next+B;
                if(up>end) up=end;
                task[1]=up;
                next=up;
                cur_B[src]=(task[1]>task[0])? (task[1]-task[0]) : 0;
                last_send_t[src]=now;
                MPI_Send(task,2,MPI_UINT64_T,src,TAG_TASK,comm);
            } else {
                MPI_Abort(comm,99);
            }
        }

        free(last_send_t);
        free(thr_keys_s);
        free(cur_B);

    } else {
        unsigned char *plain=(unsigned char*)malloc(clen_sz);
        if(!plain){ fprintf(stderr,"Rank %d: malloc plain\n", id); MPI_Abort(comm,7); }

        int req=1; MPI_Send(&req,1,MPI_INT,0,TAG_REQ,comm);
        int found_local=0;

        while(1){
            MPI_Status stw;
            MPI_Probe(0,MPI_ANY_TAG,comm,&stw);
            if(stw.MPI_TAG==TAG_STOP){
                MPI_Recv(NULL,0,MPI_BYTE,0,TAG_STOP,comm,&stw);
                break;
            } else if(stw.MPI_TAG==TAG_TASK){
                uint64_t task[2]; MPI_Recv(task,2,MPI_UINT64_T,0,TAG_TASK,comm,&stw);
                uint64_t a=task[0], b=task[1];
                if(a>=b){ MPI_Send(&req,1,MPI_INT,0,TAG_REQ,comm); continue; }
                for(uint64_t k=a;k<b;++k){
                    des_decrypt_buffer(k,cipher,clen_sz,plain);
                    local_tests++;
                    if(u8memmem(plain,clen_sz,needle,(size_t)nlen)){
                        if(!found_local){
                            found_local=1;
                            status_code=2;
                            MPI_Send(&k,1,MPI_UINT64_T,0,TAG_FOUND,comm);
                        }
                        if(allow_stop){ goto worker_exit; }
                    }
                    if(allow_stop){
                        MPI_Status stop_st;
                        int flag_stop=0; MPI_Iprobe(0,TAG_STOP,comm,&flag_stop,&stop_st);
                        if(flag_stop){ MPI_Recv(NULL,0,MPI_BYTE,0,TAG_STOP,comm,&stop_st); goto worker_exit; }
                    }
                }
                MPI_Send(&req,1,MPI_INT,0,TAG_REQ,comm);
            } else {
                MPI_Abort(comm,98);
            }
        }
worker_exit:
        free(plain);
    }

    MPI_Barrier(comm);
    double t1=MPI_Wtime();
    double local_time=t1-t0;

    double *times_all=NULL; uint64_t *tests_all=NULL; int *status_all=NULL;
    if(id==0){
        times_all=(double*)malloc(sizeof(double)*P);
        tests_all=(uint64_t*)malloc(sizeof(uint64_t)*P);
        status_all=(int*)malloc(sizeof(int)*P);
        if(!times_all||!tests_all||!status_all){ fprintf(stderr,"Root: memoria metricas\n"); MPI_Abort(comm,78); }
    }

    MPI_Gather(&local_time,1,MPI_DOUBLE,times_all,1,MPI_DOUBLE,0,comm);
    MPI_Gather(&local_tests,1,MPI_UINT64_T,tests_all,1,MPI_UINT64_T,0,comm);
    MPI_Gather(&status_code,1,MPI_INT,status_all,1,MPI_INT,0,comm);

    double t_par_max=0.0; MPI_Reduce(&local_time,&t_par_max,1,MPI_DOUBLE,MPI_MAX,0,comm);

    if(id==0){
        printf("  • Detalle por proceso\n");
        printf("    RANK |   TESTS     |  STATUS           |  TIME(s)\n");
        printf("    -----+-------------+-------------------+---------\n");
        for(int r=0;r<P;r++){
            const char *status_str=(r==0)? "MASTER" : (status_all[r]==2? "FOUND":"STOP");
            printf(" %5d | %11" PRIu64 " | %-17s | %7.4f%s\n", r, tests_all[r], status_str, times_all[r], (r==winner? "  <==":""));
        }

        printf("\n  • Resultado: %s\n", (winner>=1? "✔ Llave encontrada":"✘ No encontrada"));
        if(winner>=1){
            printf("    - Rank    : %d\n", winner);
            printf("    - Llave   : " PRIu64 "\n", found_key);
            unsigned char *plain=(unsigned char*)malloc(clen_sz+1);
            if(plain){
                des_decrypt_buffer(found_key,cipher,clen_sz,plain);
                plain[clen_sz]=0;
                printf("    - Texto   : %.*s\n", (int)clen_sz,(char*)plain);
                free(plain);
            }
        }

        printf("\n  • Resumen global\n");
        printf("    - Tiempo total (max rank): %.6f s\n\n", t_par_max);
        fflush(stdout);

        free(times_all); free(tests_all); free(status_all);
    }

    // libera buffers y finaliza mpi
    free(needle); free(cipher);
    MPI_Finalize();
    return 0;
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
