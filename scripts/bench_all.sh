# script de pruebas
set -Eeuo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJ_DIR/build_bins_opt"

# Try build_bins_opt first, fallback to bin/ for backwards compatibility
if [[ -d "$BUILD_DIR" && -x "$BUILD_DIR/bruteforce_seq" ]]; then
  BIN_DIR="$BUILD_DIR"
else
  BIN_DIR="$PROJ_DIR/bin"
fi

BIN_SEQ="$BIN_DIR/bruteforce_seq"
BIN_NAI="$BIN_DIR/bruteforce_mpi"
BIN_CYC="$BIN_DIR/bruteforce_mpi_cyclic"
BIN_DYN="$BIN_DIR/bruteforce_mpi_dynamic"
BIN_ADA="$BIN_DIR/bruteforce_mpi_dynamic_adaptive"
BIN_PER="$BIN_DIR/bruteforce_mpi_permuted"

DATA="$PROJ_DIR/data"
mkdir -p "$DATA"

# Detect cores and adjust P
if command -v nproc >/dev/null 2>&1; then
  CORES=$(nproc)
else
  CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
fi

P_REQUESTED="${P:-8}"
if [[ "$P_REQUESTED" -gt "$CORES" ]]; then
  echo "⚠ P solicitado ($P_REQUESTED) > cores($CORES). Ajustando P=$CORES y usando --oversubscribe"
  P=$CORES
  MPIRUN_EXTRA="--oversubscribe"
else
  P=$P_REQUESTED
  MPIRUN_EXTRA=""
fi

SUBSTR="${SUBSTR:-"es una prueba de"}"
TEXT="$DATA/mensaje.txt"
[[ -f "$TEXT" ]] || echo -n "Esta es una prueba de proyecto 2" > "$TEXT"

BITS_LIST=${BITS_LIST:-"21 22 23 24"}

DYN_B_LIST=${DYN_B_LIST:-"20000 50000 100000"}    
ADAPTIVE_T_LIST=${ADAPTIVE_T_LIST:-"10 30 50"}    
PERM_SEEDS=${PERM_SEEDS:-"12345 54321 2025"}      

CATEGORIES=("easy" "med" "hard")

MODE="${MODE:-full}"         
WINDOW="${WINDOW:-200000}"    

CSV="$PROJ_DIR/bench_full2.csv"

have_python() { command -v python3 >/dev/null 2>&1; }
pow2() { local b="$1"; echo $((1<<b)); }
ceil_div_int() { local a="$1" b="$2"; echo $(((a + b - 1)/b)); }

speedup() {
  local a="${1:-}" b="${2:-}"
  if [[ -z "$b" || "$b" == "0" ]]; then echo "inf"; return; fi
  if have_python; then
    python3 - "$a" "$b" <<'PY'
import sys
a=float(sys.argv[1]); b=float(sys.argv[2])
print("inf" if b<=0 else f"{a/b:.6f}")
PY
  else
    awk -v a="$a" -v b="$b" 'BEGIN{ if(b==""||b==0){print "inf";exit}; print a/b }'
  fi
}

# ======== PARSERS (leen de stdin) ========

# Quita códigos ANSI para que "FOUND" se reconozca aunque la salida tenga color
strip_ansi() {
  sed -E $'s/\x1B\\[[0-9;]*[A-Za-z]//g'
}

parse_seq_time() { awk '/Tiempo[[:space:]]*:/ {print $(NF-1); exit}'; }
parse_mpi_tmax() { awk '/Tiempo total \(max rank\)/ {print $(NF-1); exit}'; }

# Rank por línea "- Rank : X"
parse_mpi_rank_mainline() {
  awk -F':' '/- *Rank/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}'
}

# Rank desde la tabla (fila con FOUND)
parse_mpi_rank_from_table() {
  strip_ansi | awk -F'|' '
    /^[[:space:]]*[0-9]+[[:space:]]*\|/ {
      status=$3
      gsub(/\t/," ",status)
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",status)
      gsub(/[[:space:]]/,"",status)
      if (status ~ /FOUND/) {
        r=$1; gsub(/[[:space:]]/,"",r); print r; exit
      }
    }'
}

# Total tests por etiqueta (si existe)
parse_mpi_tests_total_generic() { awk -F':' '/Llaves probadas totales/ {gsub(/^[ \t]+/,"",$2); print $2; exit}'; }

# Total tests sumando la columna TESTS de la tabla
parse_mpi_tests_from_table() {
  strip_ansi | awk -F'|' '
    /^[[:space:]]*[0-9]+[[:space:]]*\|/ {
      val=$2
      gsub(/[[:space:]]/,"",val)
      if (val != "") s+=val+0
    }
    END { if(s>0) print s }'
}

# ======== helpers ========
drop_caches() {
  # Skip cache dropping if SKIP_DROP_CACHES is set or not root
  if [[ "${SKIP_DROP_CACHES:-0}" == "1" ]]; then
    return 0
  fi
  if [[ $EUID -ne 0 ]]; then
    # Try sudo, but don't fail if it doesn't work
    sudo -n sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
  else
    sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
  fi
}

ensure_bins() {
  for B in "$BIN_SEQ" "$BIN_NAI" "$BIN_CYC" "$BIN_DYN" "$BIN_ADA" "$BIN_PER"; do
    [[ -x "$B" ]] || { echo "ERROR: falta $B. Compila con 'make'."; exit 1; }
  done
}
ensure_bins

# ======== ejecutores ========
run_seq() {
  local cipher="$1" L="$2" U="$3"
  local out; out="$("$BIN_SEQ" --bruteforce -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U")"
  parse_seq_time <<<"$out"
}

run_naive() {
  local cipher="$1" L="$2" U="$3"
  local out; out="$(mpirun $MPIRUN_EXTRA -np "$P" "$BIN_NAI" -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U")"
  local tpar rank tests
  tpar="$(parse_mpi_tmax <<<"$out")"
  rank="$(parse_mpi_rank_mainline <<<"$out")"
  tests="$(parse_mpi_tests_total_generic <<<"$out")"
  echo "${tpar:-};${rank:-};${tests:-}"
}

run_cyclic() {
  local cipher="$1" L="$2" U="$3"
  local out; out="$(mpirun $MPIRUN_EXTRA -np "$P" "$BIN_CYC" -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U")"
  local tpar rank tests
  tpar="$(parse_mpi_tmax <<<"$out")"
  rank="$(parse_mpi_rank_mainline <<<"$out")"
  tests="$(parse_mpi_tests_from_table <<<"$out")"
  echo "${tpar:-};${rank:-};${tests:-}"
}

run_dynamic() {
  local cipher="$1" L="$2" U="$3" B="$4"
  local out; out="$(mpirun $MPIRUN_EXTRA -np "$P" "$BIN_DYN" -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U" -B "$B")"
  local tpar rank tests
  tpar="$(parse_mpi_tmax <<<"$out")"
  rank="$(parse_mpi_rank_mainline <<<"$out")"
  tests="$(parse_mpi_tests_from_table <<<"$out")"
  echo "${tpar:-};${rank:-};${tests:-}"
}

run_adaptive() {
  local cipher="$1" L="$2" U="$3" Tms="$4"
  local out; out="$(mpirun $MPIRUN_EXTRA -np "$P" "$BIN_ADA" -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U" -T "$Tms")"
  local tpar rank tests
  tpar="$(parse_mpi_tmax <<<"$out")"
  rank="$(parse_mpi_rank_mainline <<<"$out")"
  tests="$(parse_mpi_tests_from_table <<<"$out")"
  echo "${tpar:-};${rank:-};${tests:-}"
}

run_permuted() {
  local cipher="$1" L="$2" U="$3" seed="$4"
  local out; out="$(mpirun $MPIRUN_EXTRA -np "$P" "$BIN_PER" -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U" -R "$seed")"
  local tpar rank tests
  tpar="$(parse_mpi_tmax <<<"$out")"
  rank="$(parse_mpi_rank_mainline <<<"$out")"
  tests="$(parse_mpi_tests_from_table <<<"$out")"
  echo "${tpar:-};${rank:-};${tests:-}"
}

run_cyclic() {
  local cipher="$1" L="$2" U="$3"
  local out; out="$(mpirun -np "$P" "$BIN_CYC" -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U")"
  local tpar rank tests
  tpar="$(parse_mpi_tmax <<<"$out")"
  rank="$(parse_mpi_rank_mainline <<<"$out")"
  tests="$(parse_mpi_tests_total_generic <<<"$out")"
  echo "${tpar:-};${rank:-};${tests:-}"
}

run_dynamic() {
  local cipher="$1" L="$2" U="$3" B="$4"
  local out; out="$(mpirun -np "$P" "$BIN_DYN" -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U" -B "$B")"
  local tpar rank tests_sum
  tpar="$(parse_mpi_tmax <<<"$out")"
  rank="$(parse_mpi_rank_from_table <<<"$out")"; [[ -n "${rank:-}" ]] || rank="$(parse_mpi_rank_mainline <<<"$out")"
  tests_sum="$(parse_mpi_tests_from_table <<<"$out")"
  [[ -n "${tests_sum:-}" ]] || tests_sum="$(parse_mpi_tests_total_generic <<<"$out")"
  echo "${tpar:-};${rank:-};${tests_sum:-}"
}

run_dynamic_adaptive() {
  local cipher="$1" L="$2" U="$3" Tms="$4"
  local out; out="$(mpirun -np "$P" "$BIN_ADA" -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U" -T "$Tms")"
  local tpar rank tests_sum
  tpar="$(parse_mpi_tmax <<<"$out")"
  rank="$(parse_mpi_rank_from_table <<<"$out")"; [[ -n "${rank:-}" ]] || rank="$(parse_mpi_rank_mainline <<<"$out")"
  tests_sum="$(parse_mpi_tests_from_table <<<"$out")"
  [[ -n "${tests_sum:-}" ]] || tests_sum="$(parse_mpi_tests_total_generic <<<"$out")"
  echo "${tpar:-};${rank:-};${tests_sum:-}"
}

run_permuted() {
  local cipher="$1" L="$2" U="$3" seed="$4"
  local out; out="$(mpirun -np "$P" "$BIN_PER" -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U" -R "$seed")"
  local tpar rank tests_sum
  tpar="$(parse_mpi_tmax <<<"$out")"
  # PRIORIDAD: rank desde tabla FOUND (más confiable en permuted)
  rank="$(parse_mpi_rank_from_table <<<"$out")"; [[ -n "${rank:-}" ]] || rank="$(parse_mpi_rank_mainline <<<"$out")"
  tests_sum="$(parse_mpi_tests_from_table <<<"$out")"
  [[ -n "${tests_sum:-}" ]] || tests_sum="$(parse_mpi_tests_total_generic <<<"$out")"
  echo "${tpar:-};${rank:-};${tests_sum:-}"
}

# ======== CSV ========
echo "mode_cache,bits,U,L,U_run,category,key,P,variant,chunk_B_or_T_or_R,t_seq_s,t_par_s,speedup,rank_found,tests_total" > "$CSV"

echo
echo "== Benchmark integral (P=$P, MODE=$MODE) =="

for bits in $BITS_LIST; do
  Ufull="$(pow2 "$bits")"

  Keasy=$((Ufull/2 + 1))
  Kmed=$((Ufull/2 + Ufull/8))
  Khard=$(( $(ceil_div_int "$Ufull" 7) + $(ceil_div_int "$Ufull" 13) ))

  for category in "${CATEGORIES[@]}"; do
    case "$category" in
      easy) key="$Keasy" ;;
      med)  key="$Kmed"  ;;
      hard) key="$Khard" ;;
    esac

    cipher="$DATA/c_b${bits}_${category}.bin"
    "$BIN_SEQ" --encrypt -i "$TEXT" -k "$key" -o "$cipher" >/dev/null

    if [[ "$MODE" == "full" ]]; then
      Lrun=0; Uran="$Ufull"
    else
      local_low=$(( key - WINDOW )); (( local_low < 0 )) && local_low=0
      local_high=$(( key + WINDOW )); (( local_high > Ufull )) && local_high="$Ufull"
      Lrun="$local_low"; Uran="$local_high"
    fi

    for cache_mode in "with_cache" "no_cache"; do
      [[ "$cache_mode" == "no_cache" ]] && drop_caches || true

      # SECUENCIAL
      tseq="$(run_seq "$cipher" "$Lrun" "$Uran")"; tseq="${tseq:-}"

      # NAIVE
      IFS=';' read -r tpar_n rank_n tests_n < <(run_naive "$cipher" "$Lrun" "$Uran" || true)
      sp_n="$(speedup "$tseq" "${tpar_n:-}")"
      echo "$cache_mode,$bits,$Ufull,$Lrun,$Uran,$category,$key,$P,naive,,$tseq,${tpar_n:-},${sp_n},${rank_n:-},${tests_n:-}" >> "$CSV"

      # CÍCLICO
      IFS=';' read -r tpar_c rank_c tests_c < <(run_cyclic "$cipher" "$Lrun" "$Uran" || true)
      sp_c="$(speedup "$tseq" "${tpar_c:-}")"
      echo "$cache_mode,$bits,$Ufull,$Lrun,$Uran,$category,$key,$P,cyclic,,$tseq,${tpar_c:-},${sp_c},${rank_c:-},${tests_c:-}" >> "$CSV"

      # DINÁMICO (B)
      for B in $DYN_B_LIST; do
        IFS=';' read -r tpar_d rank_d tests_d < <(run_dynamic "$cipher" "$Lrun" "$Uran" "$B" || true)
        sp_d="$(speedup "$tseq" "${tpar_d:-}")"
        echo "$cache_mode,$bits,$Ufull,$Lrun,$Uran,$category,$key,$P,dynamic,B=$B,$tseq,${tpar_d:-},${sp_d},${rank_d:-},${tests_d:-}" >> "$CSV"
      done

      # DINÁMICO ADAPTATIVO (T)
      for Tms in $ADAPTIVE_T_LIST; do
        IFS=';' read -r tpar_a rank_a tests_a < <(run_dynamic_adaptive "$cipher" "$Lrun" "$Uran" "$Tms" || true)
        sp_a="$(speedup "$tseq" "${tpar_a:-}")"
        echo "$cache_mode,$bits,$Ufull,$Lrun,$Uran,$category,$key,$P,dynamic_adaptive,T=$Tms,$tseq,${tpar_a:-},${sp_a},${rank_a:-},${tests_a:-}" >> "$CSV"
      done

      # PERMUTED (R)
      for R in $PERM_SEEDS; do
        IFS=';' read -r tpar_p rank_p tests_p < <(run_permuted "$cipher" "$Lrun" "$Uran" "$R" || true)
        sp_p="$(speedup "$tseq" "${tpar_p:-}")"
        echo "$cache_mode,$bits,$Ufull,$Lrun,$Uran,$category,$key,$P,permuted,R=$R,$tseq,${tpar_p:-},${sp_p},${rank_p:-},${tests_p:-}" >> "$CSV"
      done

      echo "OK  bits=$bits  mode=$MODE/$cache_mode  cat=$category  key=$key  U_run=[$Lrun,$Uran)"
    done
  done
done

echo
echo "CSV listo: $CSV"
echo "Ver bonito: column -s, -t < $CSV | less -S"
echo "Top speedup: column -s, -t < $CSV | sort -k13 -nr | head -20"
