"""
benchmark_pipeline.py

Uso (ejemplo):
  # Extraer/analizar un nuevo round frente al baseline:
  python3 scripts/benchmark_pipeline.py \
    --baseline logs/bench_full.csv \
    --new artifacts/round1-20251028_101656/csv/bench_round1.csv \
    --out-dir artifacts/results_round1_$(date +%Y%m%d_%H%M%S)

Propósito:
  - Reproducible pipeline para comparar rounds y aplicar la regla de eliminación.
  - No modificar el script entre rounds: usar CLI args.
"""
from __future__ import annotations
import argparse
import os
import sys
import json
import time
import subprocess
from datetime import datetime
import pandas as pd
import numpy as np
import glob
import re
import logging

# Config / defaults

DEFAULT_TSEQ = 3.056193
DEFAULT_THRESHOLD_PCT = 10.0
DEFAULT_MIN_CATEGORIES = 2
LOG_TIME_FORMAT = "%Y%m%d_%H%M%S"


# Logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)


# Helpers

def safe_div(a, b):
    try:
        if b == 0 or pd.isna(b):
            return np.nan
        return float(a) / float(b)
    except Exception:
        return np.nan

def measure_seq_time(seq_bin, cipher_path, substr, L, U):
    """Ejecuta la versión secuencial una sola vez para medir t_seq exacto."""
    if not seq_bin or not os.path.isfile(seq_bin):
        return np.nan
    try:
        result = subprocess.run(
            [seq_bin, "--bruteforce", "-c", cipher_path, "-s", substr, "-L", str(L), "-U", str(U)],
            capture_output=True,
            text=True,
            timeout=600,
        )
        lines = result.stdout.splitlines()
        for line in lines:
            if "Tiempo" in line:
                try:
                    val = float(line.split(":")[1].split()[0])
                    return val
                except Exception:
                    continue
    except Exception as exc:
        logging.warning("No se pudo medir t_seq: %s", exc)
    return np.nan


def load_and_clean(path, measure_seq=False, seq_bin=None, cipher=None, substr=None):
    df = pd.read_csv(path, dtype=str, keep_default_na=False).replace({'': np.nan})
    for col in ["t_seq_s", "t_par_s", "speedup", "P", "L", "U"]:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")

    can_measure = (
        measure_seq
        and seq_bin and cipher and substr
        and os.path.isfile(seq_bin)
        and os.path.isfile(cipher)
    )
    if can_measure:
        logging.info("Medición on-the-fly de t_seq para filas sin valor")
        for idx, row in df.iterrows():
            current_tseq = row.get("t_seq_s")
            if pd.isna(current_tseq) or (current_tseq is not None and current_tseq <= 0):
                L = row.get("L", 0)
                U = row.get("U", 0)
                df.at[idx, "t_seq_s"] = measure_seq_time(seq_bin, cipher, substr, L, U)
    elif measure_seq:
        logging.warning("Medición de t_seq solicitada pero faltan binario o cipher (seq_bin=%s, cipher=%s)", seq_bin, cipher)
    return df


def sanitize_efficiency(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    if "speedup" in df.columns and "P" in df.columns:
        df["efficiency"] = df["speedup"] / df["P"]
        invalid = df["efficiency"] > 1.0
        count_invalid = int(invalid.sum())
        if count_invalid > 0:
            print(f"[WARN] {count_invalid} filas con eficiencia >100%, serán descartadas.")
            df.loc[invalid, "note"] = "eff>100%"
        df = df[~invalid]

    if "t_par_s" in df.columns:
        df = df.dropna(subset=["t_par_s"])
        df = df[df["t_par_s"] > 0]
    if "speedup" in df.columns:
        df = df.dropna(subset=["speedup"])
    return df

def coerce_numeric_cols(df: pd.DataFrame):
    for c in ['t_seq_s','t_par_s','P','mean_tseq','mean_tpar','speedup','eff_mean']:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors='coerce')
    if 'P' not in df.columns:
        df['P'] = 8
    df['P'] = pd.to_numeric(df['P'], errors='coerce').fillna(8).astype(float)
    return df


# Log parsing (safe, configurable)

def extract_from_logfile(logpath: str):
    """
    Extrae t_par_s, rank_found, tests_total desde un log. Regresa dict.
    - Busca 'Tiempo total (max rank)  : X s' o 'Tiempo total  : X s'
    - Busca 'Rank    : N' para rank_found
    - Suma la columna TESTS en el bloque 'Detalle por proceso' si existe
    """
    t_par = None
    rank_found = None
    tests_total = None
    try:
        with open(logpath, 'r', encoding='utf-8', errors='ignore') as fh:
            text = fh.read()
    except Exception as e:
        logging.debug(f"Could not read {logpath}: {e}")
        return {'t_par_s': None, 'rank_found': None, 'tests_total': None}

    # Tiempo paralelo
    m = re.search(r"Tiempo total .*max rank\s*:\s*([0-9]+\.[0-9]+)", text)
    if not m:
        m = re.search(r"Tiempo total\s*:\s*([0-9]+\.[0-9]+)", text)
    if m:
        t_par = float(m.group(1))

    # rank found
    m2 = re.search(r"[- ]Rank\s*[:\-]\s*([0-9]+)", text)
    if m2:
        rank_found = int(m2.group(1))

    # tests_total: sumar segunda columna del bloque "Detalle por proceso"
    # extraer líneas que tengan " | " y parezcan " rank |  12345 | ..."
    tests = 0
    found_tests = False
    for line in text.splitlines():
        if '|' in line:
            parts = [p.strip() for p in line.split('|')]
            # buscamos línea con 3+ columnas y que la segunda sea numérica (tests)
            if len(parts) >= 2 and re.fullmatch(r"[0-9]+", parts[1]):
                try:
                    tests += int(parts[1])
                    found_tests = True
                except:
                    pass
    if found_tests:
        tests_total = tests

    return {'t_par_s': t_par, 'rank_found': rank_found, 'tests_total': tests_total}


# Dataframe harmonization and metrics

def harmonize_and_fill(df: pd.DataFrame, default_tseq=DEFAULT_TSEQ, extract_logs=True):
    """
    - Coerciona columnas numéricas
    - Si t_par_s es NaN y log_file existe, intenta extraer desde el log
    - Calcula speedup_recalc y eff_recalc
    """
    df = df.copy()
    df = coerce_numeric_cols(df)
    # Ensure t_seq exists
    if 't_seq_s' not in df.columns or df['t_seq_s'].isna().all():
        df['t_seq_s'] = default_tseq

    # If extract_logs requested and log_file column exists, try to fill missing t_par_s
    if extract_logs and 'log_file' in df.columns:
        missing = df['t_par_s'].isna()
        if missing.any():
            logging.info(f"Extrayendo tiempos desde logs para {missing.sum()} filas (si están disponibles)...")
            for idx in df[missing].index:
                logf = df.at[idx, 'log_file']
                if isinstance(logf, str) and logf and os.path.isfile(logf):
                    parsed = extract_from_logfile(logf)
                    if parsed.get('t_par_s') is not None:
                        df.at[idx, 't_par_s'] = parsed['t_par_s']
                    if parsed.get('rank_found') is not None:
                        df.at[idx, 'rank_found'] = parsed['rank_found']
                    if parsed.get('tests_total') is not None:
                        df.at[idx, 'tests_total'] = parsed['tests_total']
    # After attempted extraction, ensure numeric again
    df = coerce_numeric_cols(df)

    # Filter obviously invalid rows
    df = df[~df['t_par_s'].isna()]   # remove rows with no parallel time
    df = df[df['t_par_s'] > 0]

    # compute metrics
    df['speedup_recalc'] = df.apply(lambda r: safe_div(r['t_seq_s'], r['t_par_s']), axis=1)
    df['eff_recalc'] = df.apply(lambda r: safe_div(r['speedup_recalc'], r['P']), axis=1)
    return df

def summarize(df: pd.DataFrame, by='variant'):
    agg = df.groupby(by).agg(
        runs = ('speedup_recalc', 'count'),
        mean_tseq = ('t_seq_s', 'mean'),
        mean_tpar = ('t_par_s', 'mean'),
        mean_speedup = ('speedup_recalc', 'mean'),
        median_speedup = ('speedup_recalc', 'median'),
        std_speedup = ('speedup_recalc', 'std'),
        iqr_speedup = ('speedup_recalc', lambda x: float(np.subtract(*np.percentile(x.dropna(), [75,25]))) if x.dropna().size else np.nan),
        mean_eff = ('eff_recalc', 'mean'),
        median_eff = ('eff_recalc', 'median'),
    ).reset_index()
    return agg


# Comparison and elimination rule
def compare_and_decide(baseline_df: pd.DataFrame, new_df: pd.DataFrame,
                       threshold_pct=DEFAULT_THRESHOLD_PCT, min_categories=DEFAULT_MIN_CATEGORIES):
    """
    - baseline_df and new_df are summary_by_variant and summary_by_category results
    - returns dict with diffs and decisions
    """
    # baseline_df and new_df must have a key column (variant or category)
    key = 'variant' if 'variant' in baseline_df.columns else 'category'

    merged = baseline_df.merge(new_df, on=key, how='outer', suffixes=('_base','_new'))
    # compute delta pct
    merged['delta_mean_speedup_pct'] = (merged['mean_speedup_new'] - merged['mean_speedup_base']) / merged['mean_speedup_base'] * 100
    merged['delta_mean_eff_pct'] = (merged['mean_eff_new'] - merged['mean_eff_base']) / merged['mean_eff_base'] * 100

    decisions = []
    for _, row in merged.iterrows():
        name = row[key]
        delta = row.get('delta_mean_speedup_pct', np.nan)
        # simple rule for variant-level: pass if delta >= threshold_pct
        status = 'keep' if (not pd.isna(delta) and delta >= threshold_pct) else 'review'
        decisions.append({'name': name, 'delta_mean_speedup_pct': float(delta) if not pd.isna(delta) else None, 'decision': status})
    merged = merged.sort_values(by='delta_mean_speedup_pct', ascending=False)
    return merged, decisions


# CLI / Main pipeline
def main():
    p = argparse.ArgumentParser(description="Benchmark pipeline: extract, summarize, compare, decide.")
    p.add_argument('--baseline', required=True, help='CSV baseline (bench_full.csv)')
    p.add_argument('--new', required=True, help='CSV new (bench_roundX.csv raw or extracted)')
    p.add_argument('--out-dir', default=None, help='Salida (si no, se crea artifacts/results_roundX_TIMESTAMP)')
    p.add_argument('--tseq', type=float, default=DEFAULT_TSEQ, help='t_seq_s to use if missing (default {:.6f})'.format(DEFAULT_TSEQ))
    p.add_argument('--extract-logs', action='store_true', help='Extraer t_par_s desde logs si new CSV tiene rutas')
    p.add_argument('--threshold-pct', type=float, default=DEFAULT_THRESHOLD_PCT,
                   help='Umbral porcentual para considerar mejora (default 10 por ciento)')
    p.add_argument('--min-categories', type=int, default=DEFAULT_MIN_CATEGORIES,
                   help='Número mínimo de categorías donde debe mejorar (default 2)')
    args = p.parse_args()

    # out dir
    ts = datetime.utcnow().strftime(LOG_TIME_FORMAT)
    if args.out_dir:
        out_dir = args.out_dir
    else:
        out_dir = os.path.join('artifacts', f'results_{ts}')
    os.makedirs(out_dir, exist_ok=True)
    logging.info(f"Salida -> {out_dir}")

    # load baseline & new
    logging.info("Cargando baseline CSV...")
    base_raw = load_and_clean(args.baseline, measure_seq=False)
    logging.info("Cargando new CSV...")
    new_raw = load_and_clean(
        args.new,
        measure_seq=True,
        seq_bin="build_bins_opt/bruteforce_seq",
        cipher="data/cipher.bin",
        substr="prueba",
    )

    print("INFO Normalizando baseline...")
    base_raw = sanitize_efficiency(base_raw)

    print("INFO Normalizando new...")
    new_raw = sanitize_efficiency(new_raw)

    #  Normalización automática de nombres de variantes
    def normalize_variant_name(name: str) -> str:
        if not isinstance(name, str):
            return name
        n = name.strip().lower()
        n = re.sub(r'[\s-]+', '_', n)
        n = re.sub(r'_opt$', '', n)
        n = re.sub(r'__+', '_', n)
        n = re.sub(r'^bruteforce_', '', n)
        n = re.sub(r'^mpi_', '', n)
        n = re.sub(r'^brute_', '', n)

        pattern_map = [
            ('dynamic_adaptive', r'^(dynamic_adaptive|dynamic_adaptive_.*|adaptive_opt(?:_t[0-9.]+)?|adaptive_t[0-9.]+)$'),
            ('adaptive', r'^adaptive(?:_.*)?$'),
            ('dynamic', r'^dynamic(?:_opt)?(?:_b[0-9]+)?$'),
            ('cyclic', r'^cyclic(?:_.*)?$'),
            ('permuted', r'^permuted(?:_.*)?$'),
            ('naive', r'^naive(?:_.*)?$'),
        ]

        for canonical, pattern in pattern_map:
            if re.match(pattern, n):
                return canonical

        return n

    if 'variant' in base_raw.columns:
        base_raw['variant'] = base_raw['variant'].apply(normalize_variant_name)
    if 'variant' in new_raw.columns:
        new_raw['variant'] = new_raw['variant'].apply(normalize_variant_name)

    # harmonize/extract
    logging.info("Normalizando baseline...")
    base_df = harmonize_and_fill(base_raw, default_tseq=args.tseq, extract_logs=args.extract_logs)
    logging.info("Normalizando new...")
    new_df = harmonize_and_fill(new_raw, default_tseq=args.tseq, extract_logs=args.extract_logs)

    # summaries by variant and category
    logging.info("Generando resumen por variante y categoría...")
    base_var = summarize(base_df, by='variant')
    base_cat = summarize(base_df, by='category')
    new_var = summarize(new_df, by='variant')
    new_cat = summarize(new_df, by='category')

    # save summaries
    base_var.to_csv(os.path.join(out_dir,'baseline_summary_variant.csv'), index=False)
    base_cat.to_csv(os.path.join(out_dir,'baseline_summary_category.csv'), index=False)
    new_var.to_csv(os.path.join(out_dir,'round_summary_variant.csv'), index=False)
    new_cat.to_csv(os.path.join(out_dir,'round_summary_category.csv'), index=False)

    # Compare
    logging.info("Comparando variantes (baseline vs new) ...")
    vdiff, vdec = compare_and_decide(base_var, new_var, threshold_pct=args.threshold_pct, min_categories=args.min_categories)
    vdiff.to_csv(os.path.join(out_dir,'round_vs_baseline_variant_diff.csv'), index=False)

    logging.info("Comparando categorías (baseline vs new) ...")
    cdiff, cdec = compare_and_decide(base_cat, new_cat, threshold_pct=args.threshold_pct, min_categories=args.min_categories)
    cdiff.to_csv(os.path.join(out_dir,'round_vs_baseline_category_diff.csv'), index=False)

    try:
        # build mapping variant -> list of categories in new_df (raw)
        variant_categories = {}
        raw_new = new_df.copy()
        if 'variant' in raw_new.columns and 'category' in raw_new.columns:
            for _, r in raw_new.iterrows():
                variant = r['variant']
                cat = r['category']
                variant_categories.setdefault(variant, set()).add(cat)
    except Exception:
        variant_categories = {}

    # Decide per variant (robust)
    decisions = []
    for _, row in vdiff.iterrows():
        variant = row['variant']
        delta_pct = row.get('delta_mean_speedup_pct', None)
        cats = variant_categories.get(variant, set())
        # count categories where new speedup >= baseline*(1+threshold)
        cat_count = 0
        for cat in cats:
            # find baseline category mean and new category mean for this variant-category combo
            # We approximate by checking category-level improvement (coarse)
            try:
                base_cat_row = cdiff[cdiff['category']=='easy']  # placeholder; we use category diffs below if needed
            except:
                pass
        # Simple rule fallback: if delta_pct >= threshold -> pass
        if (delta_pct is not None) and (not pd.isna(delta_pct)) and (delta_pct >= args.threshold_pct):
            decision = 'pass'
        elif (delta_pct is not None) and (not pd.isna(delta_pct)) and (delta_pct >= 0):
            decision = 'review'
        else:
            decision = 'elim'
        decisions.append({'variant': variant, 'delta_mean_speedup_pct': (float(delta_pct) if not pd.isna(delta_pct) else None), 'decision': decision, 'categories_observed': list(cats)})

    # save decisions
    result = {
        'timestamp': ts,
        'baseline_csv': args.baseline,
        'new_csv': args.new,
        'tseq_used': args.tseq,
        'threshold_pct': args.threshold_pct,
        'min_categories': args.min_categories,
        'variant_decisions': decisions
    }
    with open(os.path.join(out_dir,'decision.json'), 'w') as fh:
        json.dump(result, fh, indent=2)

    logging.info("=== Resumen rápido (top del CSV de diff) ===")
    logging.info("\n" + vdiff[['variant','mean_speedup_base','mean_speedup_new','delta_mean_speedup_pct']].to_string(index=False))
    logging.info("Decisiones guardadas en: " + os.path.join(out_dir,'decision.json'))
    print("\nOutputs written to:", out_dir)

if __name__ == '__main__':
    main()

