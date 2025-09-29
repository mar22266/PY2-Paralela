#include "util.h"
#include <ctype.h>
#include <stdio.h>
#include <string.h>

// convierte una cadena hex sin espacios a bytes retorna #bytes o -1 en error
long hex_to_bytes(const char *hex, unsigned char *out, size_t out_max) {
    size_t len = strlen(hex);
    if (len % 2 != 0) return -1;
    size_t n = len / 2;
    if (n > out_max) return -1;
    for (size_t i = 0; i < n; ++i) {
        char h = hex[2*i];
        char lc = hex[2*i+1];
        if (!isxdigit((unsigned char)h) || !isxdigit((unsigned char)lc)) return -1;
        unsigned int v;
        sscanf(&hex[2*i], "%2x", &v);
        out[i] = (unsigned char)v;
    }
    return (long)n;
}

// imprime un buffer en mayúsculas hex sin separadores seguido
void print_hex(const unsigned char *buf, size_t len) {
    for (size_t i = 0; i < len; ++i) printf("%02X", buf[i]);
    printf("\n");
}

// copia in a out y aplica zero-padding hasta múltiplo de 8 retorna tamaño final o 0 si no cabe
size_t pad_to_block8(const unsigned char *in, size_t len, unsigned char *out, size_t out_max) {
    size_t padlen = (len % 8 == 0) ? len : ((len / 8) + 1) * 8;
    if (padlen > out_max) return 0;
    memcpy(out, in, len);
    if (padlen > len) memset(out + len, 0, padlen - len); 
    return padlen;
}

// devuelve 1 si needle aparece en haystack 0 en caso contrario
int contains_substring(const char *haystack, const char *needle) {
    return strstr(haystack, needle) != NULL;
}
