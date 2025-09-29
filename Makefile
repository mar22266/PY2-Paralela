# ===========================================
# PROYECTO 2 - UVG: VERSION SECUENCIAL (PARTE A, INCISO 3)
# COMPILA CON OPENSSL (PREFERIDO) O CON rpc/des_crypt.h SI ESTA DISPONIBLE
# ===========================================

CC      ?= gcc
CFLAGS  ?= -O3 -std=c11 -Wall -Wextra -Wshadow -Wpedantic
LDFLAGS ?=
LIBS    :=
INC_DIR := include
SRC_DIR := src
BIN_DIR := bin
OBJ_DIR := build

# FUENTES (ajusta si tuvieras nombres distintos)
SOURCES := $(SRC_DIR)/bruteforce_seq.c \
           $(SRC_DIR)/des_compat.c \
           $(SRC_DIR)/timer.c \
           $(SRC_DIR)/util.c

OBJECTS := $(SOURCES:$(SRC_DIR)/%.c=$(OBJ_DIR)/%.o)
TARGET  := $(BIN_DIR)/bruteforce_seq

# HABILITA CLOCK_MONOTONIC EN <time.h>
CFLAGS += -D_POSIX_C_SOURCE=200809L

# SILENCIA DEPRECATIONS DE DES EN OPENSSL 3 (académico)
CFLAGS += -Wno-deprecated-declarations

# DETECCION SENCILLA DE OPENSSL
HAVE_OPENSSL := $(shell printf "#include <openssl/des.h>\n" | $(CC) -E -M - 2>/dev/null >/dev/null && echo 1 || echo 0)
ifeq ($(HAVE_OPENSSL),1)
  CFLAGS  += -DHAVE_OPENSSL
  LIBS    += -lcrypto
endif
# SI TU DISTRO REQUIERE librt PARA clock_gettime (raro en glibc nuevas):
# LIBS += -lrt

# CREAR DIRECTORIOS (BIN/OBJ)
$(shell mkdir -p $(BIN_DIR) $(OBJ_DIR))

.PHONY: all seq clean \
        file_crypto \
        mpi                # <--- AÑADIDO

# ===========================================
# (AÑADIDO) Nuevo binario: file_crypto
# - Permite cifrar/descifrar archivos TXT/HEX con DES-ECB (des_compat)
# - Fuentes específicas y objetos
# ===========================================
FILE_CRYPTO_SOURCES := $(SRC_DIR)/file_crypto.c $(SRC_DIR)/des_compat.c
FILE_CRYPTO_OBJECTS := $(FILE_CRYPTO_SOURCES:$(SRC_DIR)/%.c=$(OBJ_DIR)/%.o)
FILE_CRYPTO_TARGET  := $(BIN_DIR)/file_crypto

# ====== (AÑADIDO) MPI ======
# usamos mpicc para compilar/enlazar el binario MPI
MPICC ?= mpicc
MPI_TARGET := $(BIN_DIR)/bruteforce_mpi
# Compilamos y enlazamos en un solo paso con mpicc (evita problemas de includes MPI)
MPI_SOURCES := $(SRC_DIR)/bruteforce.c $(SRC_DIR)/des_compat.c

# Construye todo: secuencial + file_crypto + mpi
all: seq file_crypto mpi

# ====== (LO ORIGINAL) ======
seq: $(TARGET)

$(TARGET): $(OBJECTS)
	$(CC) $(CFLAGS) -I$(INC_DIR) $^ -o $@ $(LDFLAGS) $(LIBS)

# REGLA GENERICA DE OBJETOS (sin dependencias a headers para evitar falsos "No rule...")
$(OBJ_DIR)/%.o: $(SRC_DIR)/%.c
	$(CC) $(CFLAGS) -I$(INC_DIR) -c $< -o $@

# ====== (AÑADIDO) Regla para file_crypto ======
file_crypto: $(FILE_CRYPTO_TARGET)

$(FILE_CRYPTO_TARGET): $(FILE_CRYPTO_OBJECTS)
	$(CC) $(CFLAGS) -I$(INC_DIR) $^ -o $@ $(LDFLAGS) $(LIBS)

# ====== (AÑADIDO) Regla para bruteforce_mpi ======
mpi: $(MPI_TARGET)

$(MPI_TARGET): $(MPI_SOURCES)
	$(MPICC) $(CFLAGS) -I$(INC_DIR) $^ -o $@ $(LDFLAGS) $(LIBS)

clean:
	rm -rf $(OBJ_DIR) $(BIN_DIR)
