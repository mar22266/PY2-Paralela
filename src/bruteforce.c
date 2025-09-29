 // archivo brindado en clase... modificado para cumplir requisitos solicitados
 // usa openssl DES en lugar de rpc/des_crypt.h 
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <mpi.h>
#include <unistd.h>

#include "des_compat.h"

// define el tamaño máximo del buffer 
#define max_buf 4096

// funcion de descifrado in-place
void decrypt(long key, char *ciph, int len){
    unsigned char tmp[max_buf];
    if (len > (int)sizeof(tmp)) len = (int)sizeof(tmp);
    des_compat_decrypt((uint64_t)key, (const unsigned char*)ciph, tmp, (size_t)len);
    memcpy(ciph, tmp, (size_t)len);
}

// funcion de cifrado in-place
void encrypt(long key, char *ciph, int len){
    unsigned char tmp[max_buf];
    if (len > (int)sizeof(tmp)) len = (int)sizeof(tmp);
    des_compat_encrypt((uint64_t)key, (const unsigned char*)ciph, tmp, (size_t)len);
    memcpy(ciph, tmp, (size_t)len);
}

// logica del archivo original: busca la subcadena " the "
static char search_str[] = " the ";
int try_key(long key, char *ciph, int len){
    char temp[len+1];
    memcpy(temp, ciph, len);
    temp[len] = 0;
    decrypt(key, temp, len);
    return strstr((char*)temp, search_str) != NULL;
}

// 16 bytes + 0 final para strlen() se deja igual como el archivo subido a canvas
static unsigned char cipher[] = {
    108, 245, 65, 63, 125, 200, 150, 66,
    17, 170, 207, 170, 34, 31, 70, 215, 0
};

// funcion principal del programa MPI
int main(int argc, char *argv[]){
    int n_nodes, id;
    long upper = (1L << 56); 
    long mylower, myupper;
    MPI_Status st;
    MPI_Request req;
    int flag; 
    int ciphlen = (int)strlen((const char*)cipher);
    MPI_Comm comm = MPI_COMM_WORLD;

    // inicialización de MPI
    MPI_Init(NULL, NULL);
    MPI_Comm_size(comm, &n_nodes);
    MPI_Comm_rank(comm, &id);

    // cada nodo calcula su rango
    long range_per_node = upper / n_nodes;
    mylower = range_per_node * id;
    myupper = range_per_node * (id + 1) - 1;
    if (id == n_nodes - 1) {
        myupper = upper; 
    }

    // variables para comunicación
    long found = 0;
    long recv_key = 0; 

    // todos los ranks postean un Irecv no bloqueante
    MPI_Irecv(&recv_key, 1, MPI_LONG, MPI_ANY_SOURCE, 0, comm, &req);

    // busqueda local
    for (long i = mylower; i < myupper && (found == 0); ++i) {
        if (try_key(i, (char*)cipher, ciphlen)) {
            found = i;
            // envia a todos los nodos incluido el mismo
            for (int node = 0; node < n_nodes; ++node) {
                MPI_Send(&found, 1, MPI_LONG, node, 0, MPI_COMM_WORLD);
            }
            break;
        }
    }

    // comprobar si ya llegó el mensaje
    MPI_Wait(&req, &st);

    // el master muestra el resultado
    if (id == 0) {
        if (recv_key != 0) {
            unsigned char out[max_buf];
            des_compat_decrypt((uint64_t)recv_key, (const unsigned char*)cipher, out, (size_t)ciphlen);
            out[ciphlen] = 0;
            // muestra el resultado
            printf("========================================\n");
            printf("  brute-force mpi result (master rank 0)\n");
            printf("========================================\n");
            printf("found_key : %li\n", recv_key);
            printf("plaintext : \"%s\"\n", (char*)out);
            printf("----------------------------------------\n");
            printf("%li %s\n", recv_key, cipher); 
            fflush(stdout);
        } else {
            printf("[master] no key found in searched space.\n");
            fflush(stdout);
        }
    }

    // finalización de MPI
    MPI_Finalize();
    return 0;
}
