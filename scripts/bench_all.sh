# script de pruebas
set -Eeuo pipefail

PROJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_SEQ="$PROJ_DIR/bin/bruteforce_seq"
BIN_NAI="$PROJ_DIR/bin/bruteforce_mpi"
BIN_CYC="$PROJ_DIR/bin/bruteforce_mpi_cyclic"
BIN_DYN="$PROJ_DIR/bin/bruteforce_mpi_dynamic"
BIN_ADA="$PROJ_DIR/bin/bruteforce_mpi_dynamic_adaptive"
BIN_PER="$PROJ_DIR/bin/bruteforce_mpi_permuted"

DATA="$PROJ_DIR/data"
LOGS="$PROJ_DIR/logs"
mkdir -p "$DATA" "$LOGS"

P="${P:-8}"
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

CSV="$LOGS/bench_full2.csv"

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
  if [[ $EUID -ne 0 ]]; then
    sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
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
  local cipher="$1" L="$2" U="$3" log="$4"
  local out; out="$("$BIN_SEQ" --bruteforce -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U")"
  echo "$out" | tee "$log" >/dev/null
  parse_seq_time <<<"$out"
}

run_naive() {
  local cipher="$1" L="$2" U="$3" log="$4"
  local out; out="$(mpirun -np "$P" "$BIN_NAI" -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U")"
  echo "$out" | tee "$log" >/dev/null
  local tpar rank tests
  tpar="$(parse_mpi_tmax <<<"$out")"
  rank="$(parse_mpi_rank_mainline <<<"$out")"
  tests="$(parse_mpi_tests_total_generic <<<"$out")"
  echo "${tpar:-};${rank:-};${tests:-}"
}

run_cyclic() {
  local cipher="$1" L="$2" U="$3" log="$4"
  local out; out="$(mpirun -np "$P" "$BIN_CYC" -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U")"
  echo "$out" | tee "$log" >/dev/null
  local tpar rank tests
  tpar="$(parse_mpi_tmax <<<"$out")"
  rank="$(parse_mpi_rank_mainline <<<"$out")"
  tests="$(parse_mpi_tests_total_generic <<<"$out")"
  echo "${tpar:-};${rank:-};${tests:-}"
}

run_dynamic() {
  local cipher="$1" L="$2" U="$3" B="$4" log="$5"
  local out; out="$(mpirun -np "$P" "$BIN_DYN" -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U" -B "$B")"
  echo "$out" | tee "$log" >/dev/null
  local tpar rank tests_sum
  tpar="$(parse_mpi_tmax <<<"$out")"
  rank="$(parse_mpi_rank_from_table <<<"$out")"; [[ -n "${rank:-}" ]] || rank="$(parse_mpi_rank_mainline <<<"$out")"
  tests_sum="$(parse_mpi_tests_from_table <<<"$out")"
  [[ -n "${tests_sum:-}" ]] || tests_sum="$(parse_mpi_tests_total_generic <<<"$out")"
  echo "${tpar:-};${rank:-};${tests_sum:-}"
}

run_dynamic_adaptive() {
  local cipher="$1" L="$2" U="$3" Tms="$4" log="$5"
  local out; out="$(mpirun -np "$P" "$BIN_ADA" -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U" -T "$Tms")"
  echo "$out" | tee "$log" >/dev/null
  local tpar rank tests_sum
  tpar="$(parse_mpi_tmax <<<"$out")"
  rank="$(parse_mpi_rank_from_table <<<"$out")"; [[ -n "${rank:-}" ]] || rank="$(parse_mpi_rank_mainline <<<"$out")"
  tests_sum="$(parse_mpi_tests_from_table <<<"$out")"
  [[ -n "${tests_sum:-}" ]] || tests_sum="$(parse_mpi_tests_total_generic <<<"$out")"
  echo "${tpar:-};${rank:-};${tests_sum:-}"
}

run_permuted() {
  local cipher="$1" L="$2" U="$3" seed="$4" log="$5"
  local out; out="$(mpirun -np "$P" "$BIN_PER" -c "$cipher" -s "$SUBSTR" -L "$L" -U "$U" -R "$seed")"
  echo "$out" | tee "$log" >/dev/null
  local tpar rank tests_sum
  tpar="$(parse_mpi_tmax <<<"$out")"
  # PRIORIDAD: rank desde tabla FOUND (más confiable en permuted)
  rank="$(parse_mpi_rank_from_table <<<"$out")"; [[ -n "${rank:-}" ]] || rank="$(parse_mpi_rank_mainline <<<"$out")"
  tests_sum="$(parse_mpi_tests_from_table <<<"$out")"
  [[ -n "${tests_sum:-}" ]] || tests_sum="$(parse_mpi_tests_total_generic <<<"$out")"
  echo "${tpar:-};${rank:-};${tests_sum:-}"
}

# ======== CSV ========
echo "mode_cache,bits,U,L,U_run,category,key,P,variant,chunk_B_or_T_or_R,t_seq_s,t_par_s,speedup,rank_found,tests_total,log_file" > "$CSV"

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
      log_seq="$LOGS/sec_b${bits}_${category}_${cache_mode}.txt"
      tseq="$(run_seq "$cipher" "$Lrun" "$Uran" "$log_seq")"; tseq="${tseq:-}"

      # NAIVE
      log_nai="$LOGS/naive_b${bits}_${category}_${cache_mode}.txt"
      IFS=';' read -r tpar_n rank_n tests_n < <(run_naive "$cipher" "$Lrun" "$Uran" "$log_nai" || true)
      sp_n="$(speedup "$tseq" "${tpar_n:-}")"
      echo "$cache_mode,$bits,$Ufull,$Lrun,$Uran,$category,$key,$P,naive,,$tseq,${tpar_n:-},${sp_n},${rank_n:-},${tests_n:-},${log_nai}" >> "$CSV"

      # CÍCLICO
      log_cyc="$LOGS/cyclic_b${bits}_${category}_${cache_mode}.txt"
      IFS=';' read -r tpar_c rank_c tests_c < <(run_cyclic "$cipher" "$Lrun" "$Uran" "$log_cyc" || true)
      sp_c="$(speedup "$tseq" "${tpar_c:-}")"
      echo "$cache_mode,$bits,$Ufull,$Lrun,$Uran,$category,$key,$P,cyclic,,$tseq,${tpar_c:-},${sp_c},${rank_c:-},${tests_c:-},${log_cyc}" >> "$CSV"

      # DINÁMICO (B)
      for B in $DYN_B_LIST; do
        log_dyn="$LOGS/dynamic_b${bits}_${category}_B${B}_${cache_mode}.txt"
        IFS=';' read -r tpar_d rank_d tests_d < <(run_dynamic "$cipher" "$Lrun" "$Uran" "$B" "$log_dyn" || true)
        sp_d="$(speedup "$tseq" "${tpar_d:-}")"
        echo "$cache_mode,$bits,$Ufull,$Lrun,$Uran,$category,$key,$P,dynamic,B=$B,$tseq,${tpar_d:-},${sp_d},${rank_d:-},${tests_d:-},${log_dyn}" >> "$CSV"
      done

      # DINÁMICO ADAPTATIVO (T)
      for Tms in $ADAPTIVE_T_LIST; do
        log_ada="$LOGS/dynamic_adaptive_b${bits}_${category}_T${Tms}_${cache_mode}.txt"
        IFS=';' read -r tpar_a rank_a tests_a < <(run_dynamic_adaptive "$cipher" "$Lrun" "$Uran" "$Tms" "$log_ada" || true)
        sp_a="$(speedup "$tseq" "${tpar_a:-}")"
        echo "$cache_mode,$bits,$Ufull,$Lrun,$Uran,$category,$key,$P,dynamic_adaptive,T=$Tms,$tseq,${tpar_a:-},${sp_a},${rank_a:-},${tests_a:-},${log_ada}" >> "$CSV"
      done

      # PERMUTED (R)
      for R in $PERM_SEEDS; do
        log_per="$LOGS/permuted_b${bits}_${category}_R${R}_${cache_mode}.txt"
        IFS=';' read -r tpar_p rank_p tests_p < <(run_permuted "$cipher" "$Lrun" "$Uran" "$R" "$log_per" || true)
        sp_p="$(speedup "$tseq" "${tpar_p:-}")"
        echo "$cache_mode,$bits,$Ufull,$Lrun,$Uran,$category,$key,$P,permuted,R=$R,$tseq,${tpar_p:-},${sp_p},${rank_p:-},${tests_p:-},${log_per}" >> "$CSV"
      done

      echo "OK  bits=$bits  mode=$MODE/$cache_mode  cat=$category  key=$key  U_run=[$Lrun,$Uran)"
    done
  done
done

echo
echo "CSV listo: $CSV"
echo "Ver bonito: column -s, -t < $CSV | less -S"
echo "Top speedup: column -s, -t < $CSV | sort -k13 -nr | head -20"
