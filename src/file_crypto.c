// Cifra/descifra archivos usando DES-ECB con PKCS#7
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>

#include "des_compat.h"

// tamaño del bloque DES
#define block_size 8

// lee todo el archivo binario en memoria devuelve 1 si ok 0 en error.
static int read_file(const char *path, unsigned char **buf, size_t *len_out) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "error: no se pudo abrir '%s': %s\n", path, strerror(errno));
        return 0;
    }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 0; }
    long n = ftell(f);
    if (n < 0) { fclose(f); return 0; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return 0; }

    unsigned char *buf_local = (unsigned char*)malloc((size_t)n + 1);
    if (!buf_local) { fclose(f); return 0; }

    size_t r = fread(buf_local, 1, (size_t)n, f);
    fclose(f);
    if (r != (size_t)n) { free(buf_local); return 0; }

    buf_local[n] = 0; /* por conveniencia */
    *buf = buf_local;
    *len_out = (size_t)n;
    return 1;
}

// escribe un buffer completo a disco devuelve 1 si ok, 0 si falla
static int write_file(const char *path, const unsigned char *buf, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) {
        fprintf(stderr, "error: no se pudo abrir '%s' para escribir: %s\n", path, strerror(errno));
        return 0;
    }
    size_t w = fwrite(buf, 1, len, f);
    fclose(f);
    if (w != len) {
        fprintf(stderr, "error: escritura incompleta en '%s'\n", path);
        return 0;
    }
    return 1;
}

// true si el carácter es 0-9, a-f o A-F
static int is_hex_digit(char c) {
    return (c>='0'&&c<='9')||(c>='a'&&c<='f')||(c>='A'&&c<='F');
}

// convierte cadena HEX se ignoran espacios/nuevas líneas a bytes asigna out/out_len
static int hex_decode(const char *hex, unsigned char **out, size_t *out_len) {
    size_t n = strlen(hex);
    // ignorar espacios/nuevas líneas 
    char *clean = (char*)malloc(n + 1);
    if (!clean) return 0;
    size_t m = 0;
    for (size_t i = 0; i < n; ++i) {
        if (is_hex_digit(hex[i])) clean[m++] = hex[i];
    }
    clean[m] = 0;
    if (m % 2 != 0) { free(clean); return 0; }

    size_t bytes = m / 2;
    unsigned char *buf = (unsigned char*)malloc(bytes);
    if (!buf) { free(clean); return 0; }

    for (size_t i = 0; i < bytes; ++i) {
        char hi = clean[2*i];
        char lo = clean[2*i+1];
        unsigned vhi = (hi>='0'&&hi<='9')? hi-'0' : (hi>='a'&&hi<='f')? hi-'a'+10 : hi-'A'+10;
        unsigned vlo = (lo>='0'&&lo<='9')? lo-'0' : (lo>='a'&&lo<='f')? lo-'a'+10 : lo-'A'+10;
        buf[i] = (unsigned char)((vhi<<4) | vlo);
    }
    free(clean);
    *out = buf;
    *out_len = bytes;
    return 1;
}

// mapea un nibble [0..15] a 0..9,A..F
static char to_hex_char(unsigned x) { return (x<10)? ('0'+x) : ('A'+(x-10)); }

//  convierte bytes a cadena HEX mayúsculas asigna out_hex
static int hex_encode(const unsigned char *in, size_t len, char **out_hex) {
    char *hex = (char*)malloc(len*2 + 1);
    if (!hex) return 0;
    for (size_t i = 0; i < len; ++i) {
        hex[2*i]   = to_hex_char((in[i] >> 4) & 0xF);
        hex[2*i+1] = to_hex_char(in[i] & 0xF);
    }
    hex[len*2] = 0;
    *out_hex = hex;
    return 1;
}

// agrega relleno PKCS#7 a múltiplo de blk asigna out/out_len
static int pkcs7_pad(const unsigned char *in, size_t in_len, size_t blk, unsigned char **out, size_t *out_len) {
    size_t pad = blk - (in_len % blk);
    if (pad == 0) pad = blk;
    size_t total = in_len + pad;

    unsigned char *buf = (unsigned char*)malloc(total);
    if (!buf) return 0;

    memcpy(buf, in, in_len);
    memset(buf + in_len, (int)pad, pad);

    *out = buf;
    *out_len = total;
    return 1;
}

// valida y remueve el relleno PKCS#7 in-place actualiza len
static int pkcs7_unpad(unsigned char *buf, size_t *len, size_t blk) {
    if (*len == 0 || (*len % blk) != 0) return 0;
    unsigned char pad = buf[*len - 1];
    if (pad == 0 || pad > blk) return 0;
    for (size_t i = 0; i < pad; ++i) {
        if (buf[*len - 1 - i] != pad) return 0;
    }
    *len -= pad;
    buf[*len] = 0;
    return 1;
}

// linea de comandos donde se explica el uso del programa y ayuda
static void print_usage(void) {
    fprintf(stderr,
        "uso:\n"
        "  ./bin/file_crypto --mode enc --in <txt> --out <hex> --key <num>\n"
        "  ./bin/file_crypto --mode dec --in <hex> --out <txt> --key <num>\n"
        "notas:\n"
        "  - enc: lee texto (utf-8), aplica pkcs#7 y escribe HEX.\n"
        "  - dec: lee HEX, descifra y remueve pkcs#7.\n"
    );
}

// programa principal parsea argumentos, ejecuta enc/dec con DES-ECB y PKCS#7
int main(int argc, char **argv) {
    const char *mode = NULL;
    const char *in_path = NULL;
    const char *out_path = NULL;
    uint64_t key = 0;
    int have_key = 0;

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--mode") == 0 && i+1 < argc) {
            mode = argv[++i];
        } else if (strcmp(argv[i], "--in") == 0 && i+1 < argc) {
            in_path = argv[++i];
        } else if (strcmp(argv[i], "--out") == 0 && i+1 < argc) {
            out_path = argv[++i];
        } else if (strcmp(argv[i], "--key") == 0 && i+1 < argc) {
            key = (uint64_t)strtoull(argv[++i], NULL, 10);
            have_key = 1;
        } else {
            print_usage();
            return 1;
        }
    }

    if (!mode || !in_path || !have_key) {
        print_usage();
        return 1;
    }

    if (strcmp(mode, "enc") == 0) {
        unsigned char *plain = NULL;
        size_t plain_len = 0;
        // leer texto de entrada
        if (!read_file(in_path, &plain, &plain_len)) {
            return 1;
        }

        // aplicar PKCS#7
        unsigned char *padded = NULL;
        size_t padded_len = 0;
        if (!pkcs7_pad(plain, plain_len, block_size, &padded, &padded_len)) {
            fprintf(stderr, "error: pkcs7_pad fallo\n");
            free(plain);
            return 1;
        }

        // cifrar en DES
        unsigned char *cipher = (unsigned char*)malloc(padded_len);
        if (!cipher) {
            free(plain);
            free(padded);
            return 1;
        }
        des_compat_encrypt(key, padded, cipher, padded_len);

        // convertir a HEX
        char *hex = NULL;
        if (!hex_encode(cipher, padded_len, &hex)) {
            fprintf(stderr, "error: hex_encode fallo\n");
            free(plain); free(padded); free(cipher);
            return 1;
        }

        // salida
        if (out_path) {
            int ok = write_file(out_path, (unsigned char*)hex, strlen(hex));
            if (!ok) { free(plain); free(padded); free(cipher); free(hex); return 1; }
            printf("[enc] ok  in='%s'  out='%s'  key=%llu  bytes_in=%zu  bytes_enc=%zu\n",
                   in_path, out_path, (unsigned long long)key, plain_len, padded_len);
        } else {
            printf("%s\n", hex);
        }

        free(plain); free(padded); free(cipher); free(hex);
        return 0;

    } else if (strcmp(mode, "dec") == 0) {
        // leer HEX de entrada
        unsigned char *hexbuf = NULL;
        size_t hexlen = 0;
        if (!read_file(in_path, &hexbuf, &hexlen)) {
            return 1;
        }
        hexbuf[hexlen] = 0;

        // decodificar HEX -> bytes
        unsigned char *cipher = NULL;
        size_t cipher_len = 0;
        if (!hex_decode((char*)hexbuf, &cipher, &cipher_len)) {
            fprintf(stderr, "error: entrada no parece HEX valido\n");
            free(hexbuf);
            return 1;
        }
        free(hexbuf);

        // validar múltiplo de bloque
        if ((cipher_len % block_size) != 0) {
            fprintf(stderr, "error: el cifrado no es multiplo de 8 bytes\n");
            free(cipher);
            return 1;
        }

        // descifrar en DES
        unsigned char *plain_padded = (unsigned char*)malloc(cipher_len + 1);
        if (!plain_padded) { free(cipher); return 1; }

        des_compat_decrypt(key, cipher, plain_padded, cipher_len);
        plain_padded[cipher_len] = 0;

        // remover PKCS#7
        size_t out_len = cipher_len;
        if (!pkcs7_unpad(plain_padded, &out_len, block_size)) {
            fprintf(stderr, "error: pkcs7_unpad fallo (clave incorrecta o datos corruptos)\n");
            free(cipher); free(plain_padded);
            return 1;
        }

        // salida
        if (out_path) {
            int ok = write_file(out_path, plain_padded, out_len);
            if (!ok) { free(cipher); free(plain_padded); return 1; }
            printf("[dec] ok  in='%s'  out='%s'  key=%llu  bytes_in=%zu  bytes_dec=%zu\n",
                   in_path, out_path, (unsigned long long)key, cipher_len, out_len);
        } else {
            fwrite(plain_padded, 1, out_len, stdout);
            fputc('\n', stdout);
        }

        free(cipher); free(plain_padded);
        return 0;

    } else {
        print_usage();
        return 1;
    }
}
