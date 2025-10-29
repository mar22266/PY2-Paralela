# Round 1B - Tuning Report\n\nTimestamp: round1b-20251028_221003\n\n## Sobrevivientes de Round 1A

adaptive, cyclic, permuted

## Mejores Configuraciones por Variante

### adaptive

| Categoría | Config | Params | Speedup | Std | Efficiency |
|-----------|--------|--------|---------|-----|------------|
| easy   | T2.5       | -T 2.5          | 2.359 | 0.432 | 0.590 |
| hard   | T1.6       | -T 1.6          | 2.175 | 0.348 | 0.544 |
| med    | T1.8       | -T 1.8          | 2.206 | 0.099 | 0.551 |

### cyclic

| Categoría | Config | Params | Speedup | Std | Efficiency |
|-----------|--------|--------|---------|-----|------------|
| easy   | base       | None            | 3.085 | 0.079 | 0.771 |
| hard   | base       | None            | 3.024 | 0.524 | 0.756 |
| med    | base       | None            | 3.159 | 0.329 | 0.790 |

### permuted

| Categoría | Config | Params | Speedup | Std | Efficiency |
|-----------|--------|--------|---------|-----|------------|
| easy   | R54321     | -R 54321        | 4.940 | 0.698 | 1.235 |
| hard   | R12345     | -R 12345        | 1.718 | 0.126 | 0.429 |
| med    | R54321     | -R 54321        | 3.547 | 0.644 | 0.887 |

## Decisiones de Pase a Round 2

- **✗ NO PASA** `adaptive`: Mejoró 0 categorías (≥10%), max_eff=0.590
- **✗ NO PASA** `cyclic`: Mejoró 0 categorías (≥10%), max_eff=0.790
- **✗ NO PASA** `permuted`: Mejoró 1 categorías (≥10%), max_eff=1.235

## Finalistas

*Ninguna variante cumplió los criterios.*
