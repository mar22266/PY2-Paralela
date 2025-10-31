// incluye des utils y librerias base y openssl
#include "des_utils.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <openssl/evp.h>
#include <openssl/provider.h>


// lee archivo binario completo a memoria
int read_whole_file(const char *path, unsigned char **buf, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -2; }
    long sz = ftell(f);
    if (sz < 0) { fclose(f); return -3; }
    rewind(f);
    *buf = (unsigned char*)malloc((size_t)sz);
    if (!*buf) { fclose(f); return -4; }
    size_t n = fread(*buf, 1, (size_t)sz, f);
    fclose(f);
    if (n != (size_t)sz) { free(*buf); *buf=NULL; return -5; }
    *len = n;
    return 0;
}
// escribe buffer binario a disco
int write_whole_file(const char *path, const unsigned char *buf, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    size_t n = fwrite(buf, 1, len, f);
    fclose(f);
    return n == len ? 0 : -2;
}

// aplica relleno con ceros hasta multiplo de 8 bytes
size_t pad_zeros_alloc(const unsigned char *in, size_t len, unsigned char **out) {
    size_t rem = len % 8;
    size_t out_len = rem ? (len + (8 - rem)) : len;
    if (out_len == 0) out_len = 8;
    *out = (unsigned char*)calloc(out_len, 1);
    if (!*out) return 0;
    if (len) memcpy(*out, in, len);
    return out_len;
}

// convierte clave de 56 bits a arreglo de 8 bytes
static void key56_to_bytes(uint64_t key56, unsigned char key8[8]) {
    for (int i = 0; i < 8; ++i) key8[i] = (unsigned char)((key56 >> (8*(7-i))) & 0xFF);
}

// carga una sola vez los providers default y legacy
static int ensure_providers(void) {
    static int done = 0;
    static OSSL_PROVIDER *prov_default = NULL;
    static OSSL_PROVIDER *prov_legacy  = NULL;
    if (done) return 1;
    prov_default = OSSL_PROVIDER_load(NULL, "default");
    prov_legacy  = OSSL_PROVIDER_load(NULL, "legacy");
    done = (prov_default != NULL && prov_legacy != NULL);
    return done;
}

// obtiene el cifrador des ecb desde openssl
static EVP_CIPHER *fetch_des_ecb(void) {
    if (!ensure_providers()) return NULL;
    return EVP_CIPHER_fetch(NULL, "DES-ECB", NULL);
}

// ejecuta des ecb sin relleno usando evp
static int do_cipher(int enc, uint64_t key56,
                     const unsigned char *in, size_t len,
                     unsigned char *out) {
    unsigned char key8[8];
    key56_to_bytes(key56, key8);

    EVP_CIPHER *cipher = fetch_des_ecb();
    if (!cipher) return 0;

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) { EVP_CIPHER_free(cipher); return 0; }

    int ok = 1;
    if (enc) {
        ok &= (EVP_EncryptInit_ex(ctx, cipher, NULL, key8, NULL) == 1);
        ok &= (EVP_CIPHER_CTX_set_padding(ctx, 0), 1);
        int outl = 0, fin = 0;
        ok &= (EVP_EncryptUpdate(ctx, out, &outl, in, (int)len) == 1);
        EVP_EncryptFinal_ex(ctx, out + outl, &fin);
    } else {
        ok &= (EVP_DecryptInit_ex(ctx, cipher, NULL, key8, NULL) == 1);
        ok &= (EVP_CIPHER_CTX_set_padding(ctx, 0), 1);
        int outl = 0, fin = 0;
        ok &= (EVP_DecryptUpdate(ctx, out, &outl, in, (int)len) == 1);
        EVP_DecryptFinal_ex(ctx, out + outl, &fin);
    }

    EVP_CIPHER_CTX_free(ctx);
    EVP_CIPHER_free(cipher);
    return ok;
}

// cifra un buffer con des ecb
void des_encrypt_buffer(uint64_t key56,
                        const unsigned char *in, size_t len,
                        unsigned char *out) {
    if (!do_cipher(1, key56, in, len, out)) {
        fprintf(stderr, "ERROR: OpenSSL no pudo inicializar DES-ECB (ver providers 'legacy').\n");
        exit(1);
    }
}

// descifra un buffer con des ecb
void des_decrypt_buffer(uint64_t key56,
                        const unsigned char *in, size_t len,
                        unsigned char *out) {
    if (!do_cipher(0, key56, in, len, out)) {
        fprintf(stderr, "ERROR: OpenSSL no pudo inicializar DES-ECB (ver providers 'legacy').\n");
        exit(1);
    }
}

// prueba una clave y busca la subcadena en el texto plano
int des_try_key(uint64_t key56,
                const unsigned char *cipher, size_t len,
                const char *needle) {
    unsigned char *tmp = (unsigned char*)malloc(len + 1);
    if (!tmp) return 0;
    des_decrypt_buffer(key56, cipher, len, tmp);
    tmp[len] = 0;
    int ok = strstr((char*)tmp, needle) != NULL;
    free(tmp);
    return ok;
}
