#!/usr/bin/env bash
# scripts/run_seq_sweep.sh
# Barre 5 tamaños de espacio de llaves y mide tiempo en la versión secuencial.
# Genera logs y un CSV con resultados.

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$PROJ_DIR/bin/bruteforce_seq"
DATA="$PROJ_DIR/data"
LOGS="$PROJ_DIR/logs"

TEXT="$DATA/mensaje.txt"
SUBSTR="es una prueba de"

mkdir -p "$LOGS" "$DATA"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: no existe $BIN. Compila primero con: make"
  exit 1
fi

# Texto base (no sobreescribe si ya existe)
if [[ ! -f "$TEXT" ]]; then
  echo -n "Esta es una prueba de proyecto 2" > "$TEXT"
fi

# Pares (U, K) -> 5 tamaños
declare -a U_LIST=(1048576 4194304 16777216 67108864 268435456)   # 2^20..2^28
declare -a K_LIST=(524288 3000000 9000000 40000000 150000000)

CSV="$LOGS/seq_sweep.csv"
echo "U_range,key,time_s" > "$CSV"

printf "\n== Secuencial: barrido de tamaños ==\n\n"

for ((i=0; i<${#U_LIST[@]}; i++)); do
  U="${U_LIST[$i]}"
  K="${K_LIST[$i]}"
  CIPHER="$DATA/cipher_${U}.bin"
  OUTTXT="$LOGS/seq_${U}.txt"

  echo "-> Preparando cifrado U=$U  key=$K"
  "$BIN" --encrypt -i "$TEXT" -k "$K" -o "$CIPHER" >/dev/null

  echo "-> Buscando (rango [0,$U)) ..."
  OUT="$("$BIN" --bruteforce -c "$CIPHER" -s "$SUBSTR" -L 0 -U "$U")"
  echo "$OUT" | tee "$OUTTXT" >/dev/null

  time_s=$(echo "$OUT" | awk '/Tiempo/{print $(NF-1); exit}')
  found=$(echo "$OUT" | awk '/Llave/{print $3;  exit}')

  echo "$U,$K,$time_s" >> "$CSV"
  printf "   Resultado: key=%s  tiempo=%ss\n\n" "$found" "$time_s"
done

echo "CSV listo: $CSV"
