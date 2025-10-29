// importacion de librerias
#define _POSIX_C_SOURCE 199309L
#include "des_utils.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <inttypes.h>

// calcula llave efectiva des sin bits de paridad
static inline uint64_t des_effective_key(uint64_t k) {
    return k & ~0x0101010101010101ULL;
}

// imprime banner informativo del programa
static void banner(void) {
    puts("============================================================");
    puts("  BruteDES • Secuencial");
    puts("  - Cifra y ataca DES-ECB (OpenSSL EVP)");
    puts("  - Rango de llaves configurable [L, U)");
    puts("============================================================\n");
}

// imprime uso del programa 
static void usage(const char *p) {
    banner();
    fprintf(stderr,
      "USO:\n"
      "  (CIFRAR)     %s --encrypt   -i <in.txt> -k <key> -o <cipher.bin>\n"
      "  (BRUTEFORCE) %s --bruteforce -c <cipher.bin> -s \"substring\" [-L low] [-U up)\n"
      "\nOPCIONES:\n"
      "  -i texto de entrada   -o salida cifrada   -k llave DES (decimal o 0xHEX)\n"
      "  -c cifrado a atacar   -s subcadena valida  -L limite inferior  -U superior\n"
      "NOTA: para 2^56 usa -U 72057594037927936\n", p, p);
}

// convierte cadena a entero de 64 bits en base 10 o 16
static uint64_t parse_u64(const char *s) {
    if (s[0]=='0' && (s[1]=='x'||s[1]=='X')) return strtoull(s, NULL, 16);
    return strtoull(s, NULL, 10);
}

// devuelve tiempo monotonic en segundos como doble
static double now_secs(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv) {
     // banderas de modo cifrar o atacar y argumentos basicos
    int do_encrypt = 0, do_attack = 0;
    const char *in_txt=NULL, *out_bin=NULL, *cipher_path=NULL, *needle=NULL;
    uint64_t key=0, L=0, U=(1ULL<<24);

    // parseo simple de argumentos de linea
    for (int i=1; i<argc; ++i) {
        if (!strcmp(argv[i], "--encrypt")) do_encrypt = 1;
        else if (!strcmp(argv[i], "--bruteforce")) do_attack = 1;
        else if (!strcmp(argv[i], "-i") && i+1<argc) in_txt = argv[++i];
        else if (!strcmp(argv[i], "-o") && i+1<argc) out_bin = argv[++i];
        else if (!strcmp(argv[i], "-k") && i+1<argc) key = parse_u64(argv[++i]);
        else if (!strcmp(argv[i], "-c") && i+1<argc) cipher_path = argv[++i];
        else if (!strcmp(argv[i], "-s") && i+1<argc) needle = argv[++i];
        else if (!strcmp(argv[i], "-L") && i+1<argc) L = parse_u64(argv[++i]);
        else if (!strcmp(argv[i], "-U") && i+1<argc) U = parse_u64(argv[++i]);
        else { usage(argv[0]); return 1; }
    }

     // rama de cifrado de archivo de texto a des ecb
    if (do_encrypt) {
        if (!in_txt || !out_bin) { usage(argv[0]); return 1; }
        banner();
        unsigned char *plain=NULL, *padded=NULL, *cipher=NULL;
        size_t plen=0, blen=0;

        // lee archivo de entrada en memoria
        if (read_whole_file(in_txt, &plain, &plen) != 0) {
            fprintf(stderr, "ERROR: no se pudo leer %s\n", in_txt); return 2;
        }
        // aplica padding de ceros al multiplo de ocho
        blen = pad_zeros_alloc(plain, plen, &padded);
        // reserva buffer para salida cifrada
        cipher = (unsigned char*)malloc(blen);
        if (!cipher) { free(plain); free(padded); return 3; }

        // cifra buffer con la llave dada
        des_encrypt_buffer(key, padded, blen, cipher);

        // escribe salida cifrada a disco
        if (write_whole_file(out_bin, cipher, blen) != 0) {
            fprintf(stderr, "ERROR: no se pudo escribir %s\n", out_bin);
        } else {
            uint64_t eff = des_effective_key(key);
            printf("✔ Cifrado generado\n");
            printf("  • Entrada : %s (bytes=%zu)\n", in_txt, plen);
            printf("  • Salida  : %s (bytes=%zu, padded x8)\n", out_bin, blen);
            printf("  • Llave   : %" PRIu64 " (efectiva dec=%" PRIu64 ", hex=0x%016" PRIx64 ")\n",
                   key, eff, eff);
        }
         // libera memoria usada en cifrado
        free(plain); free(padded); free(cipher);
        return 0;
    }

     // rama de ataque por fuerza bruta secuencial
    if (do_attack) {
        if (!cipher_path || !needle) { usage(argv[0]); return 1; }
        banner();
        unsigned char *cipher=NULL; size_t clen=0;
        // lee binario cifrado completo
        if (read_whole_file(cipher_path, &cipher, &clen) != 0) {
            fprintf(stderr, "ERROR: no se pudo leer %s\n", cipher_path); return 2;
        }

        // imprime configuracion del ataque
        printf("→ BRUTEFORCE SECUENCIAL\n");
        printf("  • Archivo  : %s (bytes=%zu)\n", cipher_path, clen);
        printf("  • Subcadena: \"%s\"\n", needle);
        printf("  • Rango    : [%" PRIu64 ", %" PRIu64 ")\n", L, U);

        double t0 = now_secs();
        uint64_t found = UINT64_MAX;

        for (uint64_t k=L; k<U; ++k) {
            if (des_try_key(k, cipher, clen, needle)) { found = k; break; }
        }

        // muestra resultado y tiempo total
        double t1 = now_secs();
        if (found != UINT64_MAX) {
            unsigned char *plain = (unsigned char*)malloc(clen+1);
            des_decrypt_buffer(found, cipher, clen, plain);
            plain[clen] = 0;
            uint64_t eff = des_effective_key(found);
            puts("  • Resultado: ✔ Llave encontrada");
            printf("    - Llave   : %" PRIu64 " (efectiva dec=%" PRIu64 ", hex=0x%016" PRIx64 ")\n",
                   found, eff, eff);
            printf("    - Texto   : %s\n", plain);
            free(plain);
        } else {
            puts("  • Resultado: ✘ No encontrada en el rango");
        }
        printf("  • Tiempo   : %.6f s\n", t1 - t0);
        printf("Tiempo total (seq): %.6f s\n", t1 - t0);
        fflush(stdout);
        free(cipher);
        return 0;
    }

    // muestra uso si no se eligio ninguna operacion
    usage(argv[0]);
    return 1;
}
