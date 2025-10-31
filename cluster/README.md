# Cluster MPI - PY2-Paralela

Configuración y ejecución de bruteforce DES en cluster MPI multi-nodo.

## 🎯 Objetivo

Ejecutar bruteforce MPI en 2+ máquinas interconectadas en red local, demostrando escalabilidad real de MPI en memoria distribuida.

**Bonus:** +20% extra del proyecto

---

## 📋 Requisitos Previos

### Hardware
- 2+ máquinas en la misma red local (pueden ser Raspberry Pi, PCs, servidores)
- Conexión SSH entre nodos
- Al menos 2 cores por nodo (recomendado: 4+)

### Software en Cada Nodo
- Ubuntu/Debian (o compatible)
- OpenMPI 4.0+
- OpenSSL libcrypto
- SSH server habilitado
- NTP para sincronización de reloj

### Arquitectura
- **Homogénea:** Mismo CPU arch (x86_64 o ARM64)
- **Heterogénea:** Compilar binario específico por arquitectura

---

## 🔧 Configuración Inicial

### 1. Variables de Entorno

Edita [`cluster/scripts/config.sh`](scripts/config.sh) con tus valores:

```bash
# Usuarios y hosts
USER="rodri"                          # Usuario en todos los nodos
HOST_A="192.168.1.100"               # Host maestro (actual)
HOST_B="192.168.1.101"               # Nodo remoto 1
# HOST_C="192.168.1.102"             # Nodo remoto 2 (opcional)

# Configuración MPI
SLOTS_PER_HOST=4                      # Cores disponibles por host
NP_TOTAL=8                            # Total de procesos MPI

# Rutas
PROJECT_DIR="/home/${USER}/PY2-Paralela"
BIN_PATH="${PROJECT_DIR}/bin/bruteforce_mpi"
REMOTE_LOG_DIR="/tmp/mpi_logs"
```

---

## 🚀 Procedimiento de Setup

### Paso 0: Verificar Conectividad

```bash
# Desde host maestro
ping -c 3 192.168.1.101
ssh rodri@192.168.1.101 'echo "SSH OK"'
```

### Paso 1: Preparar Nodo Remoto

```bash
# Ejecutar desde host maestro
bash cluster/scripts/prepare_node.sh HOST_B
```

**Qué hace:**
- Instala OpenMPI, OpenSSL, dependencias
- Crea directorios del proyecto
- Configura NTP (sincronización de reloj)
- Desactiva swap temporalmente

**Output esperado:** `NODE_PREP_DONE`

---

### Paso 2: Configurar SSH sin Contraseña

```bash
# Ejecutar desde host maestro
bash cluster/scripts/setup_ssh.sh
```

**Qué hace:**
- Genera par de llaves SSH (si no existe)
- Copia llave pública a todos los nodos
- Verifica conexión sin contraseña

**Output esperado:** `SSH_OK` para cada nodo

---

### Paso 3: Verificar Arquitectura y Compilar

```bash
# Verificar compatibilidad
bash cluster/scripts/check_arch.sh

# Si necesita compilación en nodos remotos
bash cluster/scripts/compile_on_nodes.sh
```

**Casos:**
- **Mismo arch (x86_64):** Copiar binario desde maestro
- **Diferente arch (ARM64):** Compilar en cada nodo

---

### Paso 4: Crear Hostfile

```bash
# Generar hostfile automáticamente
bash cluster/scripts/generate_hostfile.sh
```

**Output:** `cluster/hosts_YYYYMMDD_HHMMSS.txt`

Ejemplo:
```
192.168.1.100 slots=4
192.168.1.101 slots=4
```

---

### Paso 5: Ejecutar Cluster MPI

```bash
# Corrida de prueba (8 procesos, 2 nodos)
bash cluster/scripts/run_mpi_cluster.sh

# Corrida específica con parámetros
bash cluster/scripts/run_mpi_cluster.sh \
  --range-start 0 \
  --range-end 8388608 \
  --processes 16
```

**Qué hace:**
- Lanza `mpirun` con hostfile
- Distribuye trabajo entre nodos
- Recolecta logs por rank
- Genera timing por nodo

---

### Paso 6: Recolectar Resultados

```bash
# Recopilar logs de todos los nodos
bash cluster/scripts/collect_logs.sh

# Generar CSV de resultados
bash cluster/scripts/aggregate_results.sh
```

**Output:** `cluster/results_YYYYMMDD_HHMMSS.csv`

Columnas:
- `run_id`: Identificador de corrida
- `rank`: Rank MPI
- `hostname`: Nodo que ejecutó
- `tests_done`: Keys probadas
- `wall_s`: Tiempo de ejecución
- `speedup`: Speedup vs secuencial

---

## 📊 Estructura de Archivos

```
cluster/
├── README.md                    # Este archivo
├── config.sh                    # Variables de configuración
├── src/                         # Código fuente cluster-aware
│   └── bruteforce_mpi_cluster.c # Versión con logging por rank
├── scripts/                     # Scripts de automatización
│   ├── prepare_node.sh         # Preparar nodo remoto
│   ├── setup_ssh.sh            # Configurar SSH sin contraseña
│   ├── check_arch.sh           # Verificar arquitecturas
│   ├── compile_on_nodes.sh     # Compilar en nodos remotos
│   ├── generate_hostfile.sh    # Crear hostfile MPI
│   ├── run_mpi_cluster.sh      # Ejecutar cluster MPI
│   ├── collect_logs.sh         # Recolectar logs de nodos
│   └── aggregate_results.sh    # Generar CSV de resultados
├── logs/                        # Logs de ejecución
├── collected_logs/              # Logs recopilados de nodos
└── results_*.csv               # Resultados agregados

```

---

## 🔬 Ejemplo de Uso Completo

```bash
# 1. Configurar variables
vim cluster/config.sh

# 2. Setup completo (una sola vez)
bash cluster/scripts/prepare_node.sh 192.168.1.101
bash cluster/scripts/setup_ssh.sh
bash cluster/scripts/check_arch.sh
bash cluster/scripts/generate_hostfile.sh

# 3. Ejecutar benchmark
bash cluster/scripts/run_mpi_cluster.sh

# 4. Recolectar resultados
bash cluster/scripts/collect_logs.sh
bash cluster/scripts/aggregate_results.sh

# 5. Ver resultados
cat cluster/results_*.csv
```

---

## 📈 Resultados Esperados

### Scaling Ideal (2 nodos, 8 cores cada uno)

| P | Nodos | t_par (s) | Speedup | Eficiencia |
|---|-------|-----------|---------|------------|
| 1 | 1 | 0.080 | 1.0x | 100% |
| 4 | 1 | 0.022 | 3.6x | 90% |
| 8 | 2 | 0.013 | 6.2x | 78% |
| 16 | 2 | 0.009 | 8.9x | 56% |

**Overhead de red:** ~5-10% adicional vs single-node

---

## ⚠️ Troubleshooting

### Error: "Permission denied (publickey)"
```bash
# Re-ejecutar setup SSH
bash cluster/scripts/setup_ssh.sh
```

### Error: "mpirun: command not found"
```bash
# Instalar OpenMPI en nodo remoto
ssh user@node "sudo apt-get install -y openmpi-bin libopenmpi-dev"
```

### Error: "Illegal instruction"
```bash
# Arquitecturas diferentes - recompilar en cada nodo
bash cluster/scripts/compile_on_nodes.sh
```

### Error: "Connection timed out"
```bash
# Verificar firewall
sudo ufw allow from 192.168.1.0/24
# O desactivar temporalmente
sudo ufw disable
```

### Error: Tiempos muy variables entre corridas
```bash
# Sincronizar relojes con NTP
bash cluster/scripts/prepare_node.sh HOST_B
```

---

## 🎓 Notas Importantes

### Binding y NUMA
```bash
# Para clusters heterogéneos, usar binding flexible
mpirun --bind-to none --map-by slot ...

# Para clusters homogéneos, binding estricto
mpirun --bind-to core --map-by socket ...
```

### Firewall
```bash
# Permitir tráfico MPI (puertos típicos: 1024-65535)
sudo ufw allow from 192.168.1.0/24
```

### NFS Compartido (Opcional)
Si los nodos comparten filesystem vía NFS, el binario y logs pueden estar en ubicación compartida:
```bash
# En /etc/fstab de cada nodo:
192.168.1.100:/home/shared /mnt/shared nfs defaults 0 0
```

---

## 📚 Referencias

- [MPI Tutorial - Running MPI Cluster](https://mpitutorial.com/tutorials/running-an-mpi-cluster-within-a-lan/)
- [OpenMPI FAQ - Running](https://www.open-mpi.org/faq/?category=running)
- [SSH Key Setup](https://www.ssh.com/academy/ssh/copy-id)

---

**Autor:** Sergio Orellana, Rodrigo Mansilla y Andre Marroquin
**Fecha:** Octubre 2025  
**Estado:** Ready for deployment
