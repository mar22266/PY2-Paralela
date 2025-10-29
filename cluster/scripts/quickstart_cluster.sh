#!/bin/bash
# ============================================================================
# quickstart_cluster.sh - Setup completo del cluster en un solo comando
# ============================================================================
# Ejecuta todos los pasos necesarios para configurar el cluster

set -euo pipefail

# Cargar configuración
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

log_info "========================================"
log_info "  Quick Start - Cluster MPI Setup"
log_info "========================================"
log_info ""

# ============================================
# VERIFICAR CONFIGURACIÓN
# ============================================

log_info "Verificando configuración..."
log_info "  Usuario: ${USER}"
log_info "  Host maestro: ${HOST_A}"
log_info "  Nodos remotos: ${ALL_HOSTS[@]:1}"
log_info "  Total procesos: ${NP_TOTAL}"
log_info ""

read -p "¿La configuración es correcta? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_warn "Edita cluster/scripts/config.sh con tus valores"
    exit 1
fi

# ============================================
# PASO 1: SETUP SSH
# ============================================

log_info ""
log_info "========================================" 
log_info "PASO 1: Configurar SSH sin contraseña"
log_info "========================================"
log_info ""

if bash "${SCRIPT_DIR}/setup_ssh.sh"; then
    log_info "✓ SSH configurado"
else
    log_error "✗ Falló setup SSH"
    exit 1
fi

# ============================================
# PASO 2: PREPARAR NODOS
# ============================================

log_info ""
log_info "========================================"
log_info "PASO 2: Preparar nodos remotos"
log_info "========================================"
log_info ""

for host in "${ALL_HOSTS[@]:1}"; do  # Skip maestro
    log_info "Preparando ${host}..."
    
    if bash "${SCRIPT_DIR}/prepare_node.sh" "${host}"; then
        log_info "✓ ${host} preparado"
    else
        log_error "✗ Falló preparación de ${host}"
        exit 1
    fi
done

# ============================================
# PASO 3: VERIFICAR ARQUITECTURAS
# ============================================

log_info ""
log_info "========================================"
log_info "PASO 3: Verificar arquitecturas"
log_info "========================================"
log_info ""

bash "${SCRIPT_DIR}/check_arch.sh"

# ============================================
# PASO 4: COMPILAR/DISTRIBUIR BINARIO
# ============================================

log_info ""
log_info "========================================"
log_info "PASO 4: Compilar y distribuir binario"
log_info "========================================"
log_info ""

# Compilar en maestro si no existe
if [[ ! -x "${BIN_PATH}" ]]; then
    log_info "Compilando en maestro..."
    cd "${PROJECT_DIR}"
    make bin/bruteforce_mpi_cyclic || {
        log_error "Falló compilación en maestro"
        exit 1
    }
fi

# Compilar en cada nodo remoto
if bash "${SCRIPT_DIR}/compile_on_nodes.sh"; then
    log_info "✓ Binarios compilados en todos los nodos"
else
    log_error "✗ Falló compilación"
    exit 1
fi

# ============================================
# PASO 5: GENERAR HOSTFILE
# ============================================

log_info ""
log_info "========================================"
log_info "PASO 5: Generar hostfile"
log_info "========================================"
log_info ""

if bash "${SCRIPT_DIR}/generate_hostfile.sh"; then
    log_info "✓ Hostfile generado"
else
    log_error "✗ Falló generación de hostfile"
    exit 1
fi

# ============================================
# PASO 6: TEST RUN
# ============================================

log_info ""
log_info "========================================"
log_info "PASO 6: Test run (opcional)"
log_info "========================================"
log_info ""

read -p "¿Ejecutar test run ahora? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_info "Ejecutando test run..."
    
    # Test con rango pequeño
    if bash "${SCRIPT_DIR}/run_mpi_cluster.sh" \
        --range-start 0 \
        --range-end 2097152 \
        --processes 4; then
        log_info "✓ Test run exitoso"
        
        # Agregar resultados
        log_info "Agregando resultados..."
        LATEST_RUN=$(ls -1t "${PROJECT_DIR}/cluster/logs/" | head -1)
        bash "${SCRIPT_DIR}/aggregate_results.sh" "${LATEST_RUN}"
    else
        log_warn "⚠ Test run falló (puede ser normal si no existe cipher.bin)"
    fi
fi

# ============================================
# RESUMEN FINAL
# ============================================

log_info ""
log_info "========================================"
log_info "✓ SETUP COMPLETO"
log_info "========================================"
log_info ""
log_info "Cluster configurado con éxito!"
log_info ""
log_info "Archivos importantes:"
log_info "  - Config: cluster/scripts/config.sh"
log_info "  - Hostfile: cluster/hosts_latest.txt"
log_info "  - Binario: ${BIN_PATH}"
log_info ""
log_info "Comandos útiles:"
log_info "  # Ejecutar cluster"
log_info "  bash cluster/scripts/run_mpi_cluster.sh"
log_info ""
log_info "  # Con parámetros custom"
log_info "  bash cluster/scripts/run_mpi_cluster.sh \\"
log_info "    --range-start 0 \\"
log_info "    --range-end 8388608 \\"
log_info "    --processes 16"
log_info ""
log_info "  # Ver resultados"
log_info "  bash cluster/scripts/aggregate_results.sh"
log_info ""
log_info "Documentación completa:"
log_info "  cat cluster/README.md"
log_info ""
