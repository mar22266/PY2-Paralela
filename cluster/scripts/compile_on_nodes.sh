#!/bin/bash
# Compilar binario en cada nodo remoto
# Para clusters heterogéneos o cuando el binario no es compatible

set -euo pipefail

# Cargar configuración
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

log_info "  Compilando en Nodos Remotos"

# Compilar en cada nodo
for host in "${ALL_HOSTS[@]}"; do
    log_info ""
    log_info "Compilando en ${host}..."
    
    # Script de compilación remoto
    COMPILE_SCRIPT=$(cat <<'EOFCOMPILE'
#!/bin/bash
set -euo pipefail

PROJECT_DIR="__PROJECT_DIR__"
cd "${PROJECT_DIR}"

echo "[${HOSTNAME}] Verificando código fuente..."
if [[ ! -f "src/bruteforce_mpi_cyclic.c" ]]; then
    echo "[${HOSTNAME}] ERROR: Código fuente no encontrado"
    echo "[${HOSTNAME}] Clonando repositorio..."
    
    # Si no existe, intentar clonar (ajusta URL)
    if [[ ! -d ".git" ]]; then
        echo "[${HOSTNAME}] ERROR: No hay código fuente ni repositorio git"
        exit 1
    fi
    
    git pull
fi

echo "[${HOSTNAME}] Compilando con flags optimizadas..."
mpicc -O3 -march=native -flto -ftree-vectorize -funroll-loops \
      -std=c11 -Wall -Wextra \
      -Iinclude \
      src/bruteforce_mpi_cyclic.c src/des_utils.c \
      -lcrypto \
      -o bin/bruteforce_mpi_cyclic

if [[ -x "bin/bruteforce_mpi_cyclic" ]]; then
    echo "[${HOSTNAME}] ✓ Compilación exitosa"
    ls -lh bin/bruteforce_mpi_cyclic
    echo "COMPILE_OK"
else
    echo "[${HOSTNAME}] ERROR: Compilación falló"
    exit 1
fi
EOFCOMPILE
)
    
    COMPILE_SCRIPT="${COMPILE_SCRIPT//__PROJECT_DIR__/${PROJECT_DIR}}"
    
    if ssh "${USER}@${host}" "bash -s" <<< "${COMPILE_SCRIPT}"; then
        log_info "✓ ${host}: Compilación exitosa"
    else
        log_error "✗ ${host}: Compilación falló"
        exit 1
    fi
done

# Verificación final
log_info ""
log_info "  Verificación Final"

ALL_OK=1
for host in "${ALL_HOSTS[@]}"; do
    if ssh "${USER}@${host}" "test -x ${BIN_PATH}"; then
        VERSION=$(ssh "${USER}@${host}" "stat -c%s ${BIN_PATH}" 2>/dev/null || echo "?")
        log_info "✓ ${host}: Binario OK (${VERSION} bytes)"
    else
        log_error "✗ ${host}: Binario NO ejecutable"
        ALL_OK=0
    fi
done

log_info ""
if [[ ${ALL_OK} -eq 1 ]]; then
    log_info "✓ Todos los nodos compilados"
    log_info ""
    log_info "Próximo paso:"
    log_info "  bash ${SCRIPT_DIR}/generate_hostfile.sh"
    exit 0
else
    log_error "✗ Algunos nodos fallaron"
    exit 1
fi
