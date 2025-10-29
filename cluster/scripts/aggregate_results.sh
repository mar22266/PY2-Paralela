#!/bin/bash
# ============================================================================
# aggregate_results.sh - Agregar logs en CSV
# ============================================================================
# Parsea logs de todos los ranks y genera CSV con resultados

set -euo pipefail

# Cargar configuración
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# ============================================
# ARGUMENTOS
# ============================================

if [[ $# -lt 1 ]]; then
    # Buscar última corrida
    LATEST_RUN=$(ls -1t "${PROJECT_DIR}/cluster/logs/" | head -1)
    if [[ -z "${LATEST_RUN}" ]]; then
        log_error "No se encontraron corridas"
        log_error "Uso: $0 <run_id>"
        exit 1
    fi
    RUN_ID="${LATEST_RUN}"
    log_info "Usando última corrida: ${RUN_ID}"
else
    RUN_ID="$1"
fi

LOG_DIR="${PROJECT_DIR}/cluster/logs/${RUN_ID}"

if [[ ! -d "${LOG_DIR}" ]]; then
    log_error "Directorio de logs no encontrado: ${LOG_DIR}"
    exit 1
fi

log_info "========================================"
log_info "  Agregando Resultados"
log_info "========================================"
log_info "Run ID: ${RUN_ID}"
log_info "Log dir: ${LOG_DIR}"

# ============================================
# PARSEAR LOGS
# ============================================

OUTPUT_CSV="${PROJECT_DIR}/cluster/results_${RUN_ID}.csv"

log_info ""
log_info "Parseando logs MPI..."

# Python script para parsear logs
python3 - <<'PYEOF' "${LOG_DIR}" "${OUTPUT_CSV}"
import sys
import os
import re
import csv
import glob
import json

log_dir = sys.argv[1]
output_csv = sys.argv[2]

print(f"[PARSER] Buscando logs en: {log_dir}")

# Buscar archivos de output MPI
mpi_out_files = glob.glob(f"{log_dir}/mpi_out/1/rank.*/*", recursive=True)
print(f"[PARSER] Encontrados {len(mpi_out_files)} archivos de output")

results = []

# Si hay archivos mpi_out (con --output-filename)
for filepath in mpi_out_files:
    print(f"[PARSER] Procesando: {filepath}")
    
    # Extraer rank y hostname del path
    # Formato típico: mpi_out/1/rank.X/hostname
    match = re.search(r'rank\.(\d+)/([^/]+)$', filepath)
    if not match:
        continue
    
    rank = int(match.group(1))
    hostname = match.group(2)
    
    try:
        with open(filepath, 'r') as f:
            content = f.read()
        
        # Buscar métricas en el output
        # Formato esperado del binario:
        # RANK X | TESTS Y | STATUS ... | TIME Z
        
        tests_match = re.search(r'TESTS[:\s]+(\d+)', content, re.IGNORECASE)
        time_match = re.search(r'TIME[:\s]+([\d\.]+)', content, re.IGNORECASE)
        status_match = re.search(r'STATUS[:\s]+(\w+)', content, re.IGNORECASE)
        
        tests_done = int(tests_match.group(1)) if tests_match else 0
        wall_s = float(time_match.group(1)) if time_match else 0.0
        status = status_match.group(1) if status_match else "UNKNOWN"
        
        results.append({
            'run_id': os.path.basename(log_dir),
            'rank': rank,
            'hostname': hostname,
            'tests_done': tests_done,
            'wall_s': wall_s,
            'status': status
        })
        
    except Exception as e:
        print(f"[PARSER] Error procesando {filepath}: {e}")

# Si no hay archivos mpi_out, buscar en logs por host
if not results:
    print("[PARSER] No se encontraron mpi_out files, buscando logs alternativos...")
    
    for host_dir in glob.glob(f"{log_dir}/*/"):
        hostname = os.path.basename(host_dir.rstrip('/'))
        
        for log_file in glob.glob(f"{host_dir}/*.log"):
            with open(log_file, 'r') as f:
                content = f.read()
            
            # Parsear contenido...
            # (similar al anterior)

# Cargar metadata si existe
metadata_file = f"{log_dir}/run_metadata.json"
metadata = {}
if os.path.exists(metadata_file):
    with open(metadata_file, 'r') as f:
        metadata = json.load(f)
    print(f"[PARSER] Metadata cargado: {metadata_file}")

# Calcular estadísticas
if results:
    total_tests = sum(r['tests_done'] for r in results)
    max_time = max(r['wall_s'] for r in results) if results else 0
    
    # Calcular speedup si tenemos tiempo secuencial
    # (asume que el benchmark secuencial tomó ~0.08s para este rango)
    seq_time = metadata.get('config', {}).get('seq_time', 0.08)
    speedup = seq_time / max_time if max_time > 0 else 0
    
    print(f"[PARSER] Total tests: {total_tests}")
    print(f"[PARSER] Max time: {max_time:.6f}s")
    print(f"[PARSER] Speedup: {speedup:.2f}x")
    
    # Añadir speedup a cada resultado
    for r in results:
        r['speedup'] = speedup
        r['t_par_s'] = max_time
        r['total_tests'] = total_tests

# Escribir CSV
if results:
    keys = ['run_id', 'rank', 'hostname', 'tests_done', 'wall_s', 'status', 't_par_s', 'speedup', 'total_tests']
    
    with open(output_csv, 'w', newline='') as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=keys)
        writer.writeheader()
        writer.writerows(results)
    
    print(f"[PARSER] ✓ CSV escrito: {output_csv}")
    print(f"[PARSER] {len(results)} filas")
else:
    print("[PARSER] ⚠ No se encontraron resultados para parsear")
    sys.exit(1)

PYEOF

if [[ $? -eq 0 ]]; then
    log_info "✓ Resultados agregados: ${OUTPUT_CSV}"
    
    # Mostrar resumen
    log_info ""
    log_info "========================================"
    log_info "  Resumen de Resultados"
    log_info "========================================"
    
    if command -v column &> /dev/null; then
        head -20 "${OUTPUT_CSV}" | column -t -s,
    else
        head -20 "${OUTPUT_CSV}"
    fi
    
    log_info ""
    log_info "CSV completo: ${OUTPUT_CSV}"
else
    log_error "✗ Falló agregación de resultados"
    exit 1
fi
