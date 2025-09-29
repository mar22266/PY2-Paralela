#ifndef des_compat_h
#define des_compat_h

#include <stddef.h>
#include <stdint.h>

/*
funciones de cifrado/descifrado DES en modo compatible con la utilidad
*/
void des_compat_encrypt(uint64_t key56, const unsigned char *in, unsigned char *out, size_t len);
void des_compat_decrypt(uint64_t key56, const unsigned char *in, unsigned char *out, size_t len);

#endif 
