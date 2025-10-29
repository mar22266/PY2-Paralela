#!/bin/bash
# ============================================================================
# run_mpi_cluster.sh - Ejecutar bruteforce en cluster MPI
# ============================================================================
# Lanza mpirun en todos los nodos y recolecta logs

set -euo pipefail

# Cargar configuración
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# ============================================
# ARGUMENTOS
# ============================================

# Defaults
RANGE_START_ARG="${RANGE_START}"
RANGE_END_ARG="${RANGE_END}"
NP_ARG="${NP_TOTAL}"
RUN_ID=$(generate_run_id)

# Parse argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        --range-start)
            RANGE_START_ARG="$2"
            shift 2
            ;;
        --range-end)
            RANGE_END_ARG="$2"
            shift 2
            ;;
        --processes|-np)
            NP_ARG="$2"
            shift 2
            ;;
        --run-id)
            RUN_ID="$2"
            shift 2
            ;;
        *)
            log_error "Argumento desconocido: $1"
            echo "Uso: $0 [--range-start N] [--range-end N] [--processes N] [--run-id ID]"
            exit 1
            ;;
    esac
done

log_info "========================================"
log_info "  Ejecutando MPI Cluster"
log_info "========================================"
log_info "Run ID: ${RUN_ID}"
log_info "Procesos: ${NP_ARG}"
log_info "Rango: [${RANGE_START_ARG}, ${RANGE_END_ARG})"

# ============================================
# VERIFICAR PREREQUISITOS
# ============================================

# Hostfile
HOSTFILE="${PROJECT_DIR}/cluster/hosts_latest.txt"
if [[ ! -f "${HOSTFILE}" ]]; then
    log_error "Hostfile no encontrado: ${HOSTFILE}"
    log_error "Ejecuta primero: bash ${SCRIPT_DIR}/generate_hostfile.sh"
    exit 1
fi

# Binario
if [[ ! -x "${BIN_PATH}" ]]; then
    log_error "Binario no ejecutable: ${BIN_PATH}"
    log_error "Ejecuta primero: bash ${SCRIPT_DIR}/compile_on_nodes.sh"
    exit 1
fi

# Cipher file
if [[ ! -f "${CIPHER_FILE}" ]]; then
    log_error "Archivo cipher no encontrado: ${CIPHER_FILE}"
    log_error "Genera primero: ./bin/bruteforce_seq --encrypt ..."
    exit 1
fi

# Copiar cipher file a todos los nodos
log_info ""
log_info "Copiando cipher file a todos los nodos..."
for host in "${ALL_HOSTS[@]}"; do
    scp -q "${CIPHER_FILE}" "${USER}@${host}:${CIPHER_FILE}" || {
        log_error "Falló copia a ${host}"
        exit 1
    }
    log_info "✓ ${host}"
done

# ============================================
# CREAR DIRECTORIO DE LOGS
# ============================================

LOG_DIR="${PROJECT_DIR}/cluster/logs/${RUN_ID}"
mkdir -p "${LOG_DIR}"

# Limpiar logs remotos
log_info ""
log_info "Preparando directorio de logs remotos..."
for host in "${ALL_HOSTS[@]}"; do
    ssh "${USER}@${host}" "rm -rf ${REMOTE_LOG_DIR}/* && mkdir -p ${REMOTE_LOG_DIR}" || true
done

# ============================================
# CONSTRUIR COMANDO MPIRUN
# ============================================

MPIRUN_CMD="mpirun"
MPIRUN_CMD+=" --hostfile ${HOSTFILE}"
MPIRUN_CMD+=" -np ${NP_ARG}"
MPIRUN_CMD+=" --bind-to ${MPI_BIND_TO}"
MPIRUN_CMD+=" --map-by ${MPI_MAP_BY}"
MPIRUN_CMD+=" --mca btl ${MPI_BTL}"
MPIRUN_CMD+=" --report-bindings"
MPIRUN_CMD+=" --output-filename ${LOG_DIR}/mpi_out"
MPIRUN_CMD+=" ${BIN_PATH}"
MPIRUN_CMD+=" -c ${CIPHER_FILE}"
MPIRUN_CMD+=" -s \"${SEARCH_STRING}\""
MPIRUN_CMD+=" -L ${RANGE_START_ARG}"
MPIRUN_CMD+=" -U ${RANGE_END_ARG}"

log_info ""
log_info "========================================"
log_info "  Comando MPI"
log_info "========================================"
log_info "${MPIRUN_CMD}"

# ============================================
# EJECUTAR MPIRUN
# ============================================

log_info ""
log_info "========================================"
log_info "  Ejecutando..."
log_info "========================================"
log_info ""

START_TIME=$(date +%s)

# Ejecutar y capturar salida
if eval "${MPIRUN_CMD}" 2>&1 | tee "${LOG_DIR}/mpi_run.log"; then
    EXIT_CODE=0
else
    EXIT_CODE=$?
fi

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

log_info ""
log_info "========================================"
log_info "  Ejecución Completada"
log_info "========================================"
log_info "Exit code: ${EXIT_CODE}"
log_info "Tiempo total: ${ELAPSED}s"
log_info "Logs en: ${LOG_DIR}"

# ============================================
# RECOLECTAR LOGS DE NODOS
# ============================================

log_info ""
log_info "Recolectando logs de todos los nodos..."

for host in "${ALL_HOSTS[@]}"; do
    log_info "Recolectando de ${host}..."
    
    # Crear subdirectorio por host
    mkdir -p "${LOG_DIR}/${host}"
    
    # Copiar logs si existen
    rsync -avz "${USER}@${host}:${REMOTE_LOG_DIR}/" "${LOG_DIR}/${host}/" 2>/dev/null || {
        log_warn "No se encontraron logs en ${host}"
    }
done

log_info "✓ Logs recolectados"

# ============================================
# GUARDAR METADATA
# ============================================

METADATA_FILE="${LOG_DIR}/run_metadata.json"

cat > "${METADATA_FILE}" <<EOF
{
  "run_id": "${RUN_ID}",
  "timestamp": "$(date -Iseconds)",
  "exit_code": ${EXIT_CODE},
  "elapsed_seconds": ${ELAPSED},
  "config": {
    "processes": ${NP_ARG},
    "nodes": ${#ALL_HOSTS[@]},
    "slots_per_node": ${SLOTS_PER_HOST},
    "range_start": ${RANGE_START_ARG},
    "range_end": ${RANGE_END_ARG},
    "search_string": "${SEARCH_STRING}",
    "binary": "${BIN_PATH}",
    "hostfile": "${HOSTFILE}"
  },
  "hosts": [
$(printf '    "%s"' "${ALL_HOSTS[@]}" | paste -sd,)
  ]
}
EOF

log_info "✓ Metadata guardado: ${METADATA_FILE}"

# ============================================
# RESUMEN FINAL
# ============================================

log_info ""
log_info "========================================"
log_info "  Resumen Final"
log_info "========================================"
log_info "Run ID: ${RUN_ID}"
log_info "Exit code: ${EXIT_CODE}"
log_info "Tiempo: ${ELAPSED}s"
log_info "Logs: ${LOG_DIR}"
log_info ""

if [[ ${EXIT_CODE} -eq 0 ]]; then
    log_info "✓ Ejecución exitosa"
    log_info ""
    log_info "Próximo paso:"
    log_info "  bash ${SCRIPT_DIR}/aggregate_results.sh ${RUN_ID}"
else
    log_error "✗ Ejecución falló"
    log_error "Revisa los logs en: ${LOG_DIR}"
fi

log_info ""

exit ${EXIT_CODE}
