#!/usr/bin/env bash
set -Eeuo pipefail
PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$PROJ_DIR/src"
BIN_DIR="$PROJ_DIR/build_bins"   # build aislado
mkdir -p "$BIN_DIR"

echo " Compilando binarios en: $BIN_DIR"

# Ensure mpicc exists before attempting to compile MPI programs.
if ! command -v mpicc >/dev/null 2>&1; then
  cat >&2 <<'MSG'
Error: "mpicc" no está disponible en PATH (mpicc: command not found).

Instale una implementación MPI (Open MPI o MPICH). Ejemplos:
  Debian/Ubuntu: sudo apt update && sudo apt install -y libopenmpi-dev openmpi-bin
  Fedora/CentOS: sudo dnf install -y openmpi openmpi-devel   # o 'yum' en sistemas más antiguos
  Arch Linux:    sudo pacman -S openmpi

Si está en un clúster, cargue el módulo MPI apropiado (por ejemplo: module load mpi/openmpi).
Después de instalar o cargar el módulo, vuelva a ejecutar este script.

Si sólo quiere compilar los binarios secuenciales y no usar MPI, edite el script o compile manualmente `bruteforce_seq.c` con gcc.
MSG
  exit 1
fi

INCLUDE_DIR="$PROJ_DIR/include"

mpicc_flags=(-O3 -march=native -std=c99 "-I$INCLUDE_DIR")
# keep a gcc_flags variant in case a non-MPI compile path is needed later
gcc_flags=(-O3 -march=native -std=c99 "-I$INCLUDE_DIR")
ldflags=()

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists openssl; then
  read -ra openssl_cflags <<<"$(pkg-config --cflags openssl)"
  if ((${#openssl_cflags[@]})); then
    mpicc_flags+=("${openssl_cflags[@]}")
    gcc_flags+=("${openssl_cflags[@]}")
  fi
  read -ra openssl_libs <<<"$(pkg-config --libs openssl)"
  if ((${#openssl_libs[@]})); then
    ldflags+=("${openssl_libs[@]}")
  fi
fi

if [[ -n "${CONDA_PREFIX:-}" ]]; then
  conda_inc="$CONDA_PREFIX/include"
  conda_lib="$CONDA_PREFIX/lib"
  if [[ -d "$conda_inc" ]]; then
    mpicc_flags+=("-I$conda_inc")
    gcc_flags+=("-I$conda_inc")
  fi
  if [[ -d "$conda_lib" ]]; then
    ldflags+=("-L$conda_lib" "-Wl,-rpath,$conda_lib")
  fi
fi

# ensure at least -lcrypto is present if pkg-config or conda flags didn't add it
has_crypto_flag=0
for flag in "${ldflags[@]}"; do
  if [[ "$flag" == "-lcrypto" || "$flag" == *"libcrypto"* ]]; then
    has_crypto_flag=1
    break
  fi
done
if (( ! has_crypto_flag )); then
  ldflags+=(-lcrypto)
fi

if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists openssl; then
  if [[ ! -f /usr/include/openssl/evp.h && ! -f /usr/local/include/openssl/evp.h && ! -f "${CONDA_PREFIX:-}/include/openssl/evp.h" ]]; then
    cat >&2 <<'MSG'
Error: Encabezados de OpenSSL (openssl/evp.h) no encontrados.

Instale los paquetes de desarrollo de OpenSSL:
  Debian/Ubuntu: sudo apt install -y libssl-dev
  Fedora/CentOS: sudo dnf install -y openssl-devel           # o 'yum'
  Arch Linux:    sudo pacman -S openssl

Alternativas sin sudo:
  • Conda: conda install -c conda-forge openssl
  • Build manual: https://www.openssl.org/source/ (configure con "--prefix=$HOME/.local/openssl" y exporte INCLUDE/LIB)

Después de instalar, reejecute este script.
MSG
    exit 1
  fi
fi

# detect availability of libcrypto and fall back to a soname if dev package is missing
tmp_test_dir="$(mktemp -d)"
tmp_test_src="$tmp_test_dir/test.c"
tmp_test_bin="$(mktemp)"
cat <<'EOF' >"$tmp_test_src"
int main(void){return 0;}
EOF
tmp_test_err="$(mktemp)"
trap 'rm -rf "$tmp_test_dir" "$tmp_test_bin" "$tmp_test_err"' EXIT

if ! mpicc "${mpicc_flags[@]}" "$tmp_test_src" -o "$tmp_test_bin" "${ldflags[@]}" >"$tmp_test_err" 2>&1; then
  mapfile -t lib_candidates < <(
    if [[ -n "${CONDA_PREFIX:-}" ]]; then
      find "$CONDA_PREFIX/lib" -maxdepth 1 -name 'libcrypto.so*' -type f 2>/dev/null | sort -V
    fi
  )
  lib_candidates=($(printf '%s
' "${lib_candidates[@]}" | awk 'NF'))
  if [[ ${#lib_candidates[@]} -eq 0 ]]; then
    system_lib="$(ldconfig -p | awk '/libcrypto\.so\.[0-9]+$/ {print $4; exit}')"
    if [[ -n "$system_lib" ]]; then
      lib_candidates=($system_lib)
    fi
  fi

  success=0
  for candidate in "${lib_candidates[@]}"; do
    echo "   • libcrypto dev symlink no disponible; usando $candidate" >&2
    new_ldflags=()
    removed=0
    for flag in "${ldflags[@]}"; do
      if [[ "$flag" == "-lcrypto" && $removed -eq 0 ]]; then
        removed=1
        continue
      fi
      new_ldflags+=("$flag")
    done
    new_ldflags+=("$candidate")
    lib_dir="$(dirname "$candidate")"
    if [[ -n "$lib_dir" ]]; then
      new_ldflags+=("-Wl,-rpath,$lib_dir")
    fi
    if mpicc "${mpicc_flags[@]}" "$tmp_test_src" -o "$tmp_test_bin" "${new_ldflags[@]}" >"$tmp_test_err" 2>&1; then
      ldflags=("${new_ldflags[@]}")
      success=1
      break
    fi
  done

  if (( ! success )); then
    echo "ERROR: Falló el enlace de prueba con libcrypto. Salida de mpicc:" >&2
    sed -n '1,40p' "$tmp_test_err" >&2
    if [[ ${#lib_candidates[@]} -eq 0 ]]; then
      cat >&2 <<'MSG'
No se encontró ninguna librería libcrypto en el sistema ni en el entorno actual.

Instale los encabezados/bibliotecas de desarrollo:
  Debian/Ubuntu: sudo apt install -y libssl-dev
  Fedora/CentOS: sudo dnf install -y openssl-devel            # o 'yum'
  Arch Linux:    sudo pacman -S openssl

Alternativas sin sudo:
  • Conda: conda install -c conda-forge openssl
  • Build manual: https://www.openssl.org/source/ (configure con "--prefix=$HOME/.local/openssl" y exporte INCLUDE/LIB)
MSG
    else
      cat >&2 <<'MSG'
Error: No se pudo enlazar con OpenSSL (libcrypto) incluso usando rutas directas.

Revise LD_LIBRARY_PATH/LIBRARY_PATH y asegúrese de que libcrypto coincida con la toolchain que está usando (por ejemplo, entorno Conda actual).
MSG
    fi
    exit 1
  fi
fi

common_sources=()
if [[ -f "$SRC/des_utils.c" ]]; then
  common_sources+=("$SRC/des_utils.c")
fi

# lista de fuentes -> nombres de binario
declare -A map
map[bruteforce_seq]="bruteforce_seq"
map[bruteforce_mpi]="bruteforce_mpi"
map[bruteforce_mpi_cyclic]="bruteforce_mpi_cyclic"
map[bruteforce_mpi_dynamic]="bruteforce_mpi_dynamic"
map[bruteforce_mpi_dynamic_adaptive]="bruteforce_mpi_dynamic_adaptive"
map[bruteforce_mpi_permuted]="bruteforce_mpi_permuted"

for src_file in "${!map[@]}"; do
  src_path="$SRC/${src_file}.c"
  out_bin="$BIN_DIR/${map[$src_file]}"
  if [[ -f "$src_path" ]]; then
    echo " - Compilando $src_path -> $out_bin"
    mpicc "${mpicc_flags[@]}" "$src_path" "${common_sources[@]}" -o "$out_bin" "${ldflags[@]}"
    chmod +x "$out_bin"
  else
    echo " ! Fuente no encontrada: $src_path  (se omite)"
  fi
done

echo " Compilación finalizada. Binarios en: $BIN_DIR"
