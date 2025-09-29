// Programa de fuerza bruta secuencial para DES secuencial
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "des_compat.h"
#include "timer.h"
#include "util.h"

/*
constantes y funciones de ayuda
*/
#define max_buf 4096
#define block 8

/*
función de uso y ayuda
*/
static void usage(void) {
    fprintf(stderr,
        "Uso\n"
        "----\n"
        "Herramienta para generar cifrados de prueba o realizar búsqueda por fuerza bruta\n\n"

        "Modos\n"
        "  Modo prueba (genera un cifrado de ejemplo):\n"
        "    bruteforce_seq --mode TEST  --plain \"TEXTO\" --key K\n\n"

        "  Modo brute force (búsqueda secuencial en el espacio de claves):\n"
        "    bruteforce_seq --mode BRUTE --cipher-hex HEX --search \"SUBSTR\" --bits B\n\n"

        "Opciones adicionales\n"
        "  --start S --end E  Especifica un rango de claves [S..E] como alternativa a --bits.\n"

        "Notas\n"
        "  - El texto se procesa en bloques de 8 bytes; para la demo se utiliza zero-padding\n"
        "    cuando un bloque no está completo.\n"
        "  - Para pruebas de rendimiento, ajuste el parámetro --bits según el alcance deseado.\n"
    );
}

// prepara bloques a partir de texto plano
static size_t prepare_blocks_from_plain(const char *plain, unsigned char *buf, size_t bufmax) {
    return pad_to_block8((const unsigned char*)plain, strlen(plain), buf, bufmax);
}

// intenta descifrar con la clave dada y busca la subcadena en el resultado
static int try_key(uint64_t key, const unsigned char *ciph, size_t len, const char *search) {
    unsigned char tmp[max_buf];
    if (len > sizeof(tmp)) return 0;
    des_compat_decrypt(key, ciph, tmp, len);
    size_t safe = (len < sizeof(tmp)-1) ? len : (sizeof(tmp)-1);
    tmp[safe] = 0;
    return contains_substring((const char*)tmp, search);
}

// main del programa de fuerza bruta secuencial
int main(int argc, char **argv) {
    const char *mode = NULL;
    const char *plain = NULL;
    const char *search = NULL;
    const char *hex = NULL;
    uint64_t key = 0;
    int have_key = 0;
    int have_bits = 0;
    unsigned bits = 0;
    uint64_t start = 0, end = 0;
    int have_range = 0;

    // for para iterar argumentos
    for (int i = 1; i < argc; ++i) {
        if      (!strcmp(argv[i], "--mode") && i+1 < argc) mode = argv[++i];
        else if (!strcmp(argv[i], "--plain") && i+1 < argc) plain = argv[++i];
        else if (!strcmp(argv[i], "--key")   && i+1 < argc) { key = strtoull(argv[++i], NULL, 0); have_key = 1; }
        else if (!strcmp(argv[i], "--cipher-hex") && i+1 < argc) hex = argv[++i];
        else if (!strcmp(argv[i], "--search") && i+1 < argc) search = argv[++i];
        else if (!strcmp(argv[i], "--bits") && i+1 < argc) { bits = (unsigned)strtoul(argv[++i], NULL, 0); have_bits = 1; }
        else if (!strcmp(argv[i], "--start") && i+1 < argc) { start = strtoull(argv[++i], NULL, 0); have_range = 1; }
        else if (!strcmp(argv[i], "--end")   && i+1 < argc) { end   = strtoull(argv[++i], NULL, 0); have_range = 1; }
        else { usage(); return 1; }
    }

    if (!mode) { usage(); return 1; }

    // si es modo test se corre la demo
    if (!strcmp(mode, "TEST")) {
        if (!plain || !have_key) { usage(); return 1; }
        unsigned char pbuf[max_buf], cbuf[max_buf], dbuf[max_buf];
        size_t blen = prepare_blocks_from_plain(plain, pbuf, sizeof(pbuf));
        if (!blen) { fprintf(stderr, "ERROR: PADDING\n"); return 1; }

        des_compat_encrypt(key, pbuf, cbuf, blen);
        printf("[TEST] KEY=%llu\n", (unsigned long long)key);
        printf("[TEST] PLAIN_LEN=%zu  CIPH_LEN=%zu\n", strlen(plain), blen);
        printf("[TEST] CIPH_HEX="); print_hex(cbuf, blen);

        des_compat_decrypt(key, cbuf, dbuf, blen);
        dbuf[blen < sizeof(dbuf)-1 ? blen : sizeof(dbuf)-1] = 0;
        printf("[TEST] DEC(HEX)=\"%s\"\n", (char*)dbuf);
        return 0;
    }

    // si es modo brute se corre la búsqueda
    if (!strcmp(mode, "BRUTE")) {
        if ((!hex || !search) || (!have_bits && !have_range)) { usage(); return 1; }

        unsigned char ciph[max_buf];
        long nbytes = hex_to_bytes(hex, ciph, sizeof(ciph));
        if (nbytes <= 0 || (nbytes % block) != 0) {
            fprintf(stderr, "ERROR: CIPHER_HEX INVALIDO O LONGITUD NO MULTIPLO DE 8.\n");
            return 1;
        }
        size_t clen = (size_t)nbytes;

        uint64_t l = 0, u = 0;
        if (have_bits) {
            if (bits >= 56) { u = (1ULL<<56) - 1ULL; }
            else             u = (1ULL<<bits) - 1ULL;
            l = 0;
        } else {
            l = start;
            u = end;
            if (u < l) { fprintf(stderr, "ERROR: RANGO INVALIDO.\n"); return 1; }
        }

        timer_mono_t t; timer_start(&t);

        uint64_t found = 0;
        int ok = 0;
        for (uint64_t k = l; k <= u; ++k) {
            if (try_key(k, ciph, clen, search)) { found = k; ok = 1; break; }
            if (k == u) break; 
        }

        // se para el timer
        timer_stop(&t);
        double sec = timer_seconds(&t);

        // si se encontró, se descifra y muestra el texto
        if (ok) {
            unsigned char dec[max_buf];
            des_compat_decrypt(found, ciph, dec, clen);
            dec[(clen < sizeof(dec)-1) ? clen : sizeof(dec)-1] = 0;

            printf("[BRUTE] ENCONTRADA=1 KEY=%llu\n", (unsigned long long)found);
            printf("[BRUTE] TIEMPO=%.6f s RANGO=[%llu..%llu] ITER=%llu\n",
                   sec, (unsigned long long)l, (unsigned long long)u,
                   (unsigned long long)(found - l + 1));
            printf("[BRUTE] TEXTO=\"%s\"\n", (char*)dec);
        } else {
            printf("[BRUTE] ENCONTRADA=0 TIEMPO=%.6f s RANGO=[%llu..%llu]\n",
                   sec, (unsigned long long)l, (unsigned long long)u);
        }
        return 0;
    }

    // si no es ninguno de los modos conocidos, se muestra ayuda
    usage();
    return 1;
}
