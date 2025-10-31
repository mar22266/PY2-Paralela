#!/bin/bash
# Generar hostfile para MPI
# Crea archivo hosts_TIMESTAMP.txt con configuración de nodos

set -euo pipefail

# Cargar configuración
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

RUN_ID=$(generate_run_id)
HOSTFILE="${PROJECT_DIR}/cluster/hosts_${RUN_ID}.txt"

log_info "========================================"
log_info "  Generando Hostfile MPI"
log_info "========================================"

# Crear hostfile

log_info "Creando hostfile: ${HOSTFILE}"

cat > "${HOSTFILE}" <<EOF
# MPI Hostfile - Generated $(date)
# Total nodes: ${#ALL_HOSTS[@]}
# Slots per host: ${SLOTS_PER_HOST}
# Total processes: ${NP_TOTAL}

EOF

for host in "${ALL_HOSTS[@]}"; do
    echo "${host} slots=${SLOTS_PER_HOST}" >> "${HOSTFILE}"
    log_info "  + ${host} slots=${SLOTS_PER_HOST}"
done

log_info ""
log_info "✓ Hostfile creado: ${HOSTFILE}"

# Crear symlink al último

LATEST_LINK="${PROJECT_DIR}/cluster/hosts_latest.txt"
ln -sf "${HOSTFILE}" "${LATEST_LINK}"
log_info "✓ Symlink: ${LATEST_LINK} -> hosts_${RUN_ID}.txt"

# Verificar conectividad

log_info ""
log_info "Verificando conectividad a todos los hosts..."

ALL_OK=1
for host in "${ALL_HOSTS[@]}"; do
    if ssh -o ConnectTimeout=5 "${USER}@${host}" "echo PING_OK" > /dev/null 2>&1; then
        log_info "✓ ${host}: Alcanzable"
    else
        log_error "✗ ${host}: NO alcanzable"
        ALL_OK=0
    fi
done

if [[ ${ALL_OK} -eq 0 ]]; then
    log_error ""
    log_error "Algunos hosts no son alcanzables"
    log_error "Verifica la configuración de red y SSH"
    exit 1
fi

# Mostrar configuración final

log_info ""
log_info "========================================"
log_info "  Configuración Final"
log_info "========================================"
log_info "Hostfile: ${HOSTFILE}"
log_info "Nodos: ${#ALL_HOSTS[@]}"
log_info "Slots/nodo: ${SLOTS_PER_HOST}"
log_info "Total procesos: ${NP_TOTAL}"
log_info ""
log_info "Contenido del hostfile:"
log_info "----------------------------------------"
cat "${HOSTFILE}" | grep -v "^#" | grep -v "^$"
log_info "----------------------------------------"

log_info ""
log_info "Próximo paso:"
log_info "  bash ${SCRIPT_DIR}/run_mpi_cluster.sh"
log_info ""
