// Compatibilidad DES usando OpenSSL DES-ECB con clave empaquetada en uint64_t.
#include "des_compat.h"
#include <string.h>
#include <openssl/des.h> 

// convierte key56 56 bits efectivos a DES_cblock con paridad impar por byte
static void key56_to_descblock(uint64_t key56, DES_cblock *k) {
    for (int i = 0; i < 8; ++i) {
        (*k)[i] = (unsigned char)((key56 >> (i * 8)) & 0xFFu);
    }
    DES_set_odd_parity(k);
}

// ECB DES procesa bloques de 8 bytes usando DES_ENCRYPT o DES_DECRYPT.
static void core(uint64_t key56, const unsigned char *in, unsigned char *out, size_t len, int enc) {
    DES_cblock k;
    DES_key_schedule sched;
    key56_to_descblock(key56, &k);
    DES_set_key_unchecked(&k, &sched);
    for (size_t i = 0; i < len; i += 8) {
        DES_cblock ib, ob;
        memcpy(ib, in + i, 8);
        DES_ecb_encrypt(&ib, &ob, &sched, enc);
        memcpy(out + i, ob, 8);
    }
}

// Cifra en DES len debe ser múltiplo de 8.
void des_compat_encrypt(uint64_t key56, const unsigned char *in, unsigned char *out, size_t len) {
    core(key56, in, out, len, 1);
}

// Descifra en DES len debe ser múltiplo de 8.
void des_compat_decrypt(uint64_t key56, const unsigned char *in, unsigned char *out, size_t len) {
    core(key56, in, out, len, 0);
}
