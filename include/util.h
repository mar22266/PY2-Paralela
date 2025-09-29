#ifndef util_h
#define util_h

#include <stddef.h>
#include <stdint.h>

/* convierte hex a asccii bytes */
long hex_to_bytes(const char *hex, unsigned char *out, size_t out_max);

/* imprime bytes como hex */
void print_hex(const unsigned char *buf, size_t len);

/* padding a multiplo de 8 */
size_t pad_to_block8(const unsigned char *in, size_t len, unsigned char *out, size_t out_max);

/* busca substring en buffer ascii */
int contains_substring(const char *haystack, const char *needle);

#endif
