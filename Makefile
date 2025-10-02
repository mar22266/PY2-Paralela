# ================================
#  PY2-Paralela - Makefile
#  OpenMPI + OpenSSL (DES, EVP API)
# ================================

MPICC := mpicc
CC    := gcc

BIN   := bin
SRC   := src
INC   := include
DATA  := data
LOG   := logs

CSTD          := -std=c11
CWARN         := -Wall -Wextra -Wshadow -Wpedantic
COPTS         := -O3 -march=native -mtune=native
CDEFS         := -D_POSIX_C_SOURCE=200809L
CFLAGS_COMMON := $(CSTD) $(CWARN) $(COPTS) $(CDEFS) -I$(INC)
LDFLAGS       := -lcrypto

SEQ_SRC := $(SRC)/bruteforce_seq.c $(SRC)/des_utils.c
MPI_SRC := $(SRC)/bruteforce_mpi.c $(SRC)/des_utils.c

SEQ_BIN := $(BIN)/bruteforce_seq
MPI_BIN := $(BIN)/bruteforce_mpi

.PHONY: all clean dirs

all: dirs $(SEQ_BIN) $(MPI_BIN)

dirs:
	@mkdir -p $(BIN) $(DATA) $(LOG)

$(SEQ_BIN): $(SEQ_SRC) $(INC)/des_utils.h
	$(CC) $(CFLAGS_COMMON) -o $@ $(SEQ_SRC) $(LDFLAGS)

$(MPI_BIN): $(MPI_SRC) $(INC)/des_utils.h
	$(MPICC) $(CFLAGS_COMMON) -o $@ $(MPI_SRC) $(LDFLAGS)

clean:
	@rm -rf $(BIN) $(LOG)/*.txt
	@echo "CLEAN OK"
