#!/bin/bash
# ============================================================================
# check_arch.sh - Verificar arquitecturas de CPU en todos los nodos
# ============================================================================
# Detecta si los nodos tienen la misma arquitectura

set -euo pipefail

# Cargar configuración
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

log_info "========================================"
log_info "  Verificando Arquitecturas"
log_info "========================================"

# ============================================
# VERIFICAR CADA NODO
# ============================================

declare -A ARCH_MAP
declare -A OS_MAP

for host in "${ALL_HOSTS[@]}"; do
    log_info ""
    log_info "Verificando ${host}..."
    
    # Obtener arquitectura
    ARCH=$(ssh "${USER}@${host}" "uname -m" 2>/dev/null || echo "UNKNOWN")
    ARCH_MAP["${host}"]="${ARCH}"
    
    # Obtener OS info
    OS=$(ssh "${USER}@${host}" "lsb_release -d 2>/dev/null | cut -f2 || uname -s" 2>/dev/null || echo "UNKNOWN")
    OS_MAP["${host}"]="${OS}"
    
    # Obtener OpenMPI version
    OMPI_VERSION=$(ssh "${USER}@${host}" "mpirun --version 2>/dev/null | head -1" 2>/dev/null || echo "NOT INSTALLED")
    
    # Obtener cores
    CORES=$(ssh "${USER}@${host}" "nproc" 2>/dev/null || echo "?")
    
    log_info "  - Arquitectura: ${ARCH}"
    log_info "  - OS: ${OS}"
    log_info "  - OpenMPI: ${OMPI_VERSION}"
    log_info "  - Cores: ${CORES}"
done

# ============================================
# ANALIZAR COMPATIBILIDAD
# ============================================

log_info ""
log_info "========================================"
log_info "  Análisis de Compatibilidad"
log_info "========================================"

# Obtener arquitectura única
UNIQUE_ARCHS=($(printf '%s\n' "${ARCH_MAP[@]}" | sort -u))

if [[ ${#UNIQUE_ARCHS[@]} -eq 1 ]]; then
    log_info "✓ Cluster HOMOGÉNEO"
    log_info "  Todas las máquinas tienen: ${UNIQUE_ARCHS[0]}"
    log_info ""
    log_info "Recomendación:"
    log_info "  - Compilar binario en cualquier nodo"
    log_info "  - Copiar binario a todos los nodos"
    log_info ""
    log_info "Próximo paso:"
    log_info "  bash ${SCRIPT_DIR}/compile_and_distribute.sh"
else
    log_warn "⚠ Cluster HETEROGÉNEO"
    log_warn "  Arquitecturas detectadas: ${UNIQUE_ARCHS[*]}"
    log_warn ""
    log_warn "Recomendación:"
    log_warn "  - Compilar binario específico en cada nodo"
    log_warn "  - O usar compilación cruzada"
    log_warn ""
    log_warn "Próximo paso:"
    log_warn "  bash ${SCRIPT_DIR}/compile_on_nodes.sh"
fi

# ============================================
# VERIFICAR BINARIO EXISTENTE
# ============================================

log_info ""
log_info "========================================"
log_info "  Verificando Binario Existente"
log_info "========================================"

MASTER_ARCH="${ARCH_MAP[${HOST_A}]}"

if [[ -f "${BIN_PATH}" ]]; then
    log_info "✓ Binario existe en maestro: ${BIN_PATH}"
    
    # Verificar en todos los nodos
    for host in "${ALL_HOSTS[@]}"; do
        if ssh "${USER}@${host}" "test -x ${BIN_PATH}"; then
            log_info "✓ ${host}: Binario ejecutable"
        else
            log_warn "⚠ ${host}: Binario NO encontrado o no ejecutable"
        fi
    done
else
    log_warn "⚠ Binario NO existe en maestro"
    log_info "  Debes compilar primero"
fi

log_info ""
log_info "========================================"
log_info "  Resumen"
log_info "========================================"
echo ""
printf "%-20s %-15s %-30s\n" "HOST" "ARCH" "STATUS"
echo "------------------------------------------------------------"
for host in "${ALL_HOSTS[@]}"; do
    ARCH="${ARCH_MAP[${host}]}"
    
    if ssh "${USER}@${host}" "test -x ${BIN_PATH}" 2>/dev/null; then
        STATUS="✓ Binario OK"
    else
        STATUS="✗ Binario falta"
    fi
    
    printf "%-20s %-15s %-30s\n" "${host}" "${ARCH}" "${STATUS}"
done

log_info ""
