#!/bin/bash
# Preparar nodo remoto para cluster MPI
# Uso: bash prepare_node.sh <hostname>

set -euo pipefail

# Cargar configuración
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# Argumentos

if [[ $# -lt 1 ]]; then
    log_error "Uso: $0 <hostname>"
    log_error "Ejemplo: $0 192.168.1.101"
    exit 1
fi

TARGET_HOST="$1"

log_info "========================================"
log_info "  Preparando Nodo: ${TARGET_HOST}"
log_info "========================================"

# Verificar conectividad

log_info "Verificando conectividad SSH..."
if ! ssh -o ConnectTimeout=${SSH_TIMEOUT} -o BatchMode=yes "${USER}@${TARGET_HOST}" 'echo SSH_TEST_OK' > /dev/null 2>&1; then
    log_warn "No se puede conectar sin contraseña. Ejecuta primero:"
    log_warn "  bash ${SCRIPT_DIR}/setup_ssh.sh"
    log_error "Conexión SSH fallida"
    exit 1
fi
log_info "✓ Conectividad SSH OK"

# Script de preparación remoto
log_info "Creando script de preparación remoto..."

REMOTE_SCRIPT=$(cat <<'EOFSCRIPT'
#!/bin/bash
set -euo pipefail

USER="__USER__"
PROJECT_DIR="__PROJECT_DIR__"
REMOTE_LOG_DIR="__REMOTE_LOG_DIR__"

echo "[REMOTE] Iniciando preparación del nodo..."

# 1. Actualizar repositorios
echo "[REMOTE] Actualizando repositorios..."
sudo apt-get update -y > /dev/null 2>&1 || {
    echo "[REMOTE] ERROR: No se pudo actualizar repositorios"
    exit 1
}

# 2. Instalar dependencias básicas
echo "[REMOTE] Instalando dependencias básicas..."
sudo apt-get install -y \
    build-essential \
    gcc \
    g++ \
    make \
    wget \
    rsync \
    openssh-server \
    ntp \
    git \
    > /dev/null 2>&1 || {
    echo "[REMOTE] ERROR: Falló instalación de dependencias básicas"
    exit 1
}

# 3. Instalar OpenMPI
echo "[REMOTE] Instalando OpenMPI..."
if ! command -v mpirun &> /dev/null; then
    sudo apt-get install -y \
        openmpi-bin \
        openmpi-common \
        libopenmpi-dev \
        > /dev/null 2>&1 || {
        echo "[REMOTE] ERROR: Falló instalación de OpenMPI"
        exit 1
    }
fi

# Verificar instalación
OMPI_VERSION=$(mpirun --version 2>/dev/null | head -1 || echo "unknown")
echo "[REMOTE] OpenMPI instalado: ${OMPI_VERSION}"

# 4. Instalar OpenSSL
echo "[REMOTE] Instalando OpenSSL..."
sudo apt-get install -y \
    libssl-dev \
    openssl \
    > /dev/null 2>&1 || {
    echo "[REMOTE] ERROR: Falló instalación de OpenSSL"
    exit 1
}

# 5. Crear directorios del proyecto
echo "[REMOTE] Creando directorios..."
mkdir -p "${PROJECT_DIR}"
mkdir -p "${PROJECT_DIR}/bin"
mkdir -p "${PROJECT_DIR}/data"
mkdir -p "${PROJECT_DIR}/cluster/logs"
chown -R "${USER}:${USER}" "${PROJECT_DIR}" || true

# 6. Crear directorio para logs temporales
sudo rm -rf "${REMOTE_LOG_DIR}"
mkdir -p "${REMOTE_LOG_DIR}"
sudo chown -R "${USER}:${USER}" "${REMOTE_LOG_DIR}"

# 7. Configurar NTP para sincronización de reloj
echo "[REMOTE] Configurando NTP..."
sudo systemctl enable ntp > /dev/null 2>&1 || true
sudo systemctl restart ntp > /dev/null 2>&1 || true

# 8. Verificar sincronización de tiempo
TIME_OFFSET=$(ntpdate -q pool.ntp.org 2>/dev/null | grep offset | awk '{print $10}' | head -1 || echo "0")
echo "[REMOTE] Time offset: ${TIME_OFFSET} seconds"

# 9. Ajustes opcionales para performance
echo "[REMOTE] Aplicando ajustes de performance..."

# Desactivar swap temporalmente
sudo swapoff -a || true
echo "[REMOTE] Swap desactivado"

# CPU governor a performance (si disponible)
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance | sudo tee "$cpu" > /dev/null 2>&1 || true
    done
    echo "[REMOTE] CPU governor: performance"
fi

# 10. Información del sistema
echo "[REMOTE] Información del sistema:"
echo "  - OS: $(lsb_release -d 2>/dev/null | cut -f2 || uname -s)"
echo "  - Arch: $(uname -m)"
echo "  - Cores: $(nproc)"
echo "  - RAM: $(free -h | grep Mem | awk '{print $2}')"
echo "  - Hostname: $(hostname)"

echo "NODE_PREP_DONE"
EOFSCRIPT
)

# Reemplazar variables en el script
REMOTE_SCRIPT="${REMOTE_SCRIPT//__USER__/${USER}}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__PROJECT_DIR__/${PROJECT_DIR}}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__REMOTE_LOG_DIR__/${REMOTE_LOG_DIR}}"

# Script de preparación remoto

log_info "Ejecutando preparación en nodo remoto..."
log_info "(Esto puede tomar varios minutos...)"

if ssh "${USER}@${TARGET_HOST}" "bash -s" <<< "${REMOTE_SCRIPT}"; then
    log_info ""
    log_info "========================================"
    log_info "✓ Nodo ${TARGET_HOST} preparado exitosamente"
    log_info "========================================"
    log_info ""
    log_info "Próximo paso:"
    log_info "  bash ${SCRIPT_DIR}/check_arch.sh"
    exit 0
else
    log_error ""
    log_error "========================================"
    log_error "✗ Falló preparación del nodo ${TARGET_HOST}"
    log_error "========================================"
    log_error ""
    log_error "Revisa los errores arriba y reintenta"
    exit 1
fi
