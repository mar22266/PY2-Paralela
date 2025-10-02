#ifndef DES_UTILS_H
#define DES_UTILS_H

#include <stddef.h>
#include <stdint.h>

int read_whole_file(const char *path, unsigned char **buf, size_t *len);
int write_whole_file(const char *path, const unsigned char *buf, size_t len);

size_t pad_zeros_alloc(const unsigned char *in, size_t len, unsigned char **out);

void des_encrypt_buffer(uint64_t key56,
                        const unsigned char *in, size_t len,
                        unsigned char *out);

void des_decrypt_buffer(uint64_t key56,
                        const unsigned char *in, size_t len,
                        unsigned char *out);

int des_try_key(uint64_t key56,
                const unsigned char *cipher, size_t len,
                const char *needle);

#endif /* DES_UTILS_H */
