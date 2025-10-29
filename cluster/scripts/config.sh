#!/bin/bash
# ============================================================================
# config.sh - Variables de configuración para cluster MPI
# ============================================================================
# Edita este archivo con tus valores específicos antes de ejecutar scripts

# ============================================
# CONFIGURACIÓN DE HOSTS
# ============================================

# Usuario (debe existir en todos los nodos con mismo nombre)
export USER_LOCAL="rodri"

# Usuario en nodo remoto
export USER_REMOTE="rodri14"

# Usar en scripts
export USER="${USER_REMOTE}"  # Para SSH al nodo remoto"

# Host maestro (desde donde se ejecuta mpirun)
# Usa localhost porque estamos ejecutando desde esta máquina
export HOST_A="localhost"
export HOST_B="node-remote"  # ← Usar nombre en vez de IP
export ALL_HOSTS=("${HOST_A}" "${HOST_B}")

# ============================================
# CONFIGURACIÓN MPI
# ============================================

# Cores/slots disponibles por host
export SLOTS_PER_HOST=4

# Total de procesos MPI a lanzar
export NP_TOTAL=8

# Binding strategy
# - "core": Bind to core (recomendado para homogéneo)
# - "none": No binding (recomendado para heterogéneo)
export MPI_BIND_TO="core"

# Mapping strategy
# - "slot": Round-robin por slot
# - "socket": Por socket NUMA
export MPI_MAP_BY="slot"

# ============================================
# RUTAS DEL PROYECTO
# ============================================

# Directorio raíz del proyecto (debe ser igual en todos los nodos)
export PROJECT_DIR="/home/${USER}/PY2-Paralela"

# Ruta del binario MPI
export BIN_PATH="${PROJECT_DIR}/bin/bruteforce_mpi_cyclic"

# Directorio para logs temporales en cada nodo
export REMOTE_LOG_DIR="/tmp/mpi_logs"

# Directorio para logs recolectados (maestro)
export COLLECTED_LOGS_DIR="${PROJECT_DIR}/cluster/collected_logs"

# ============================================
# CONFIGURACIÓN DEL BENCHMARK
# ============================================

# Rango de búsqueda por defecto
export RANGE_START=0
export RANGE_END=8388608  # 2^23

# Archivo cipher
export CIPHER_FILE="${PROJECT_DIR}/data/cipher.bin"

# Substring a buscar
export SEARCH_STRING="es una prueba de"

# ============================================
# CONFIGURACIÓN DE RED
# ============================================

# Puerto SSH (default: 22)
export SSH_PORT=22

# Timeout para conexiones SSH (segundos)
export SSH_TIMEOUT=10

# MPI transport layer (btl)
# - "tcp": TCP/IP estándar
# - "openib": InfiniBand (si disponible)
# - "sm": Shared memory (solo intra-nodo)
export MPI_BTL="tcp,sm,self"

# ============================================
# CONFIGURACIÓN AVANZADA
# ============================================

# Prefijo para archivos de salida
export OUTPUT_PREFIX="mpi_cluster"

# Nivel de verbosidad
# - 0: Solo errores
# - 1: Info básica
# - 2: Debug completo
export VERBOSE=1

# Usar colores en output
export USE_COLORS=1

# ============================================
# FUNCIONES AUXILIARES
# ============================================

# Generar Run ID único
generate_run_id() {
    date +"%Y%m%d_%H%M%S"
}

# Colores para output
if [[ ${USE_COLORS} -eq 1 ]]; then
    export RED='\033[0;31m'
    export GREEN='\033[0;32m'
    export YELLOW='\033[1;33m'
    export BLUE='\033[0;34m'
    export NC='\033[0m' # No Color
else
    export RED=''
    export GREEN=''
    export YELLOW=''
    export BLUE=''
    export NC=''
fi

# Log function
log_info() {
    if [[ ${VERBOSE} -ge 1 ]]; then
        echo -e "${GREEN}[INFO]${NC} $1"
    fi
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [[ ${VERBOSE} -ge 2 ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# Verificar si estamos en el directorio correcto
check_project_dir() {
    if [[ ! -d "${PROJECT_DIR}/cluster" ]]; then
        log_error "No se encuentra ${PROJECT_DIR}/cluster"
        log_error "Asegúrate de estar en el directorio correcto"
        exit 1
    fi
}

# Exportar todas las variables
export -f generate_run_id log_info log_warn log_error log_debug check_project_dir

log_info "Configuración cargada: ${#ALL_HOSTS[@]} hosts, ${NP_TOTAL} procesos"
