# ============================================================================
# Makefile para compilación en cluster MPI
# ============================================================================
# Compila bruteforce_mpi_cyclic con flags optimizadas

CC = mpicc
CFLAGS = -O3 -march=native -flto -ftree-vectorize -funroll-loops \
         -fomit-frame-pointer -fno-common -DNDEBUG
CFLAGS += -std=c11 -Wall -Wextra -pedantic
LDFLAGS = -lcrypto

TARGET = ../bin/bruteforce_mpi_cyclic
SOURCES = bruteforce_mpi_cyclic.c des_utils.c
OBJECTS = $(SOURCES:.c=.o)

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(OBJECTS)
	@echo "Linking $(TARGET)..."
	@mkdir -p ../bin
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "✓ Compilación exitosa: $(TARGET)"
	@ls -lh $(TARGET)

%.o: %.c
	@echo "Compilando $<..."
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	@echo "Limpiando..."
	@rm -f $(OBJECTS) $(TARGET)
	@echo "✓ Limpio"

# Información del sistema
info:
	@echo "========================================="
	@echo "Información del Sistema"
	@echo "========================================="
	@echo "Compiler: $(CC)"
	@echo "Version: $$($(CC) --version | head -1)"
	@echo "Arch: $$(uname -m)"
	@echo "OS: $$(uname -s)"
	@echo "Cores: $$(nproc)"
	@echo "Flags: $(CFLAGS)"
	@echo "========================================="
