#!/bin/bash
# ============================================================================
# setup_ssh.sh - Configurar SSH sin contraseña entre nodos
# ============================================================================
# Genera par de llaves SSH y las distribuye a todos los nodos

set -euo pipefail

# Cargar configuración
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

log_info "========================================"
log_info "  Configurando SSH Sin Contraseña"
log_info "========================================"

# ============================================
# GENERAR PAR DE LLAVES (SI NO EXISTE)
# ============================================

SSH_KEY="${HOME}/.ssh/id_ed25519"

if [[ -f "${SSH_KEY}" ]]; then
    log_info "✓ Llave SSH ya existe: ${SSH_KEY}"
else
    log_info "Generando nuevo par de llaves SSH..."
    ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -C "mpi-cluster-${USER}"
    log_info "✓ Par de llaves generado"
fi

# ============================================
# DISTRIBUIR LLAVE A TODOS LOS NODOS
# ============================================

for host in "${ALL_HOSTS[@]}"; do
    log_info ""
    log_info "Configurando ${host}..."
    
    # Verificar si ya está configurado
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${USER}@${host}" 'echo SSH_OK' > /dev/null 2>&1; then
        log_info "✓ ${host} ya configurado (SSH sin contraseña funciona)"
        continue
    fi
    
    log_info "Copiando llave pública a ${host}..."
    log_warn "Se te pedirá la contraseña de ${USER}@${host}"
    
    if ssh-copy-id -i "${SSH_KEY}.pub" "${USER}@${host}"; then
        log_info "✓ Llave copiada a ${host}"
        
        # Verificar
        if ssh -o BatchMode=yes "${USER}@${host}" 'echo SSH_OK' > /dev/null 2>&1; then
            log_info "✓ Verificación OK: SSH sin contraseña funciona"
        else
            log_error "✗ Verificación falló para ${host}"
            exit 1
        fi
    else
        log_error "✗ Falló copia de llave a ${host}"
        log_error "Verifica que:"
        log_error "  1. El host ${host} es accesible"
        log_error "  2. El usuario ${USER} existe en ${host}"
        log_error "  3. SSH server está corriendo en ${host}"
        exit 1
    fi
done

# ============================================
# VERIFICACIÓN FINAL
# ============================================

log_info ""
log_info "========================================"
log_info "  Verificación Final"
log_info "========================================"

ALL_OK=1
for host in "${ALL_HOSTS[@]}"; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${USER}@${host}" 'echo SSH_OK' > /dev/null 2>&1; then
        log_info "✓ ${host}: SSH OK"
    else
        log_error "✗ ${host}: SSH FAILED"
        ALL_OK=0
    fi
done

log_info ""
if [[ ${ALL_OK} -eq 1 ]]; then
    log_info "========================================"
    log_info "✓ SSH configurado exitosamente"
    log_info "========================================"
    log_info ""
    log_info "Próximo paso:"
    log_info "  bash ${SCRIPT_DIR}/check_arch.sh"
    exit 0
else
    log_error "========================================"
    log_error "✗ Algunos nodos fallaron"
    log_error "========================================"
    exit 1
fi
