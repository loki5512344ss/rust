#!/usr/bin/env python3
"""Paired ABBA block-bootstrap analyzer (NOT Mann-Whitney U).

Input CSV: scenario,block,variant,ns; independent blocks with A/B replicates.
Effect: median of log(median(A_block) / median(B_block)), back-transformed.
Percentile confidence intervals resample complete paired blocks. By default
Bonferroni alpha/m adjustment uses the number of scenarios in the CSV, controlling
a family of exploratory intervals *if* the individual bootstrap CIs achieve
nominal coverage; bootstrap median CI coverage is fragile at small block count.
This script cannot verify measurement order, system load or independence.
The included sample CSV is SYNTHETIC: not a Rust speed measurement.
"""
import argparse
import csv
import math
import random
import statistics
from collections import defaultdict


def percentile(data, fraction):
    if not 0 <= fraction <= 1:
        raise ValueError('fraction must be in [0, 1]')
    ordered = sorted(data)
    x = (len(ordered) - 1) * fraction
    left, right = math.floor(x), math.ceil(x)
    if left == right:
        return ordered[left]
    return ordered[left] * (right - x) + ordered[right] * (x - left)


def analyze(path, iterations, seed, alpha=0.05, multiplicity='bonferroni', min_effect_percent=0.0):
    if not 0 < alpha < 1 or not math.isfinite(alpha):
        raise ValueError('alpha must be a finite number in (0, 1)')
    if multiplicity not in ('bonferroni', 'none'):
        raise ValueError('multiplicity must be bonferroni or none')
    if not math.isfinite(min_effect_percent) or min_effect_percent < 0:
        raise ValueError('min_effect_percent must be a finite nonnegative number')
    samples = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    with open(path, newline='', encoding='utf-8') as stream:
        reader = csv.DictReader(stream)
        if not reader.fieldnames or not {'scenario', 'block', 'variant', 'ns'}.issubset(reader.fieldnames):
            raise ValueError('missing CSV columns: scenario,block,variant,ns')
        for row in reader:
            scenario = row['scenario'].strip()
            block = row['block'].strip()
            variant = row['variant'].strip().upper()
            if not scenario or not block or variant not in ('A', 'B'):
                raise ValueError(f'invalid scenario/block/variant: {row!r}')
            try:
                ns = float(row['ns'])
            except (TypeError, ValueError) as exc:
                raise ValueError(f'bad ns: {row!r}') from exc
            if not math.isfinite(ns) or ns <= 0:
                raise ValueError(f'ns must be finite and positive: {row!r}')
            samples[scenario][block][variant].append(ns)

    if not samples:
        raise ValueError('no measurements')
    m = len(samples)
    per_comparison_alpha = alpha / m if multiplicity == 'bonferroni' else alpha
    rng = random.Random(seed)
    output = []
    min_factor = 1.0 + min_effect_percent / 100

    for scenario in sorted(samples):
        log_ratios = []
        for block, variants in samples[scenario].items():
            if not variants['A'] or not variants['B']:
                raise ValueError(f'{scenario}/{block}: incomplete A/B block')
            a = statistics.median(variants['A'])
            b = statistics.median(variants['B'])
            log_ratios.append(math.log(a / b))
        estimate = statistics.median(log_ratios)
        bootstrap = [statistics.median(rng.choices(log_ratios, k=len(log_ratios)))
                     for _ in range(iterations)]
        lo = math.exp(percentile(bootstrap, per_comparison_alpha / 2))
        hi = math.exp(percentile(bootstrap, 1 - per_comparison_alpha / 2))
        speedup = math.exp(estimate)
        status = ('uncertain' if len(log_ratios) < 10 else
                  'B faster' if lo > min_factor else
                  'B slower' if hi < 1 / min_factor else 'uncertain')
        output.append((scenario, len(log_ratios), speedup, lo, hi, status))
    return output, m, per_comparison_alpha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('csv_file')
    parser.add_argument('--iterations', type=int, default=10000)
    parser.add_argument('--seed', type=int, default=20261109)
    parser.add_argument('--alpha', type=float, default=0.05,
                        help='familywise alpha (default 0.05)')
    parser.add_argument('--multiplicity', choices=['bonferroni', 'none'],
                        default='bonferroni', help='adjust intervals for scenario count')
    parser.add_argument('--min-effect-percent', type=float, default=0.0,
                        help='predeclared minimum engineering effect (default 0 percent)')
    args = parser.parse_args()
    if args.iterations < 100:
        parser.error('--iterations must be >= 100')
    try:
        out, m, per_alpha = analyze(args.csv_file, args.iterations, args.seed,
                                     args.alpha, args.multiplicity, args.min_effect_percent)
    except ValueError as exc:
        parser.error(str(exc))
    print(f'scenarios={m}, family_alpha={args.alpha:g}, '
          f'multiplicity={args.multiplicity}, individual_CI_level={100*(1-per_alpha):.3f}%, '
          f'min_effect={args.min_effect_percent:g}%, analysis=paired_bootstrap')
    for scenario, count, speedup, lo, hi, status in out:
        print(f'{scenario}: blocks={count}, median(A/B)={speedup:.4f}, '
              f'adjusted_CI=[{lo:.4f}, {hi:.4f}], {status}')
        if count < 10:
            print('  Warning: fewer than 10 paired blocks: exploratory, forced uncertain.')
    print('Note: bootstrap median CIs are heuristic with few blocks; independent '
          'replication and correctness checks required. No Mann-Whitney U is computed.')


if __name__ == '__main__':
    main()
