#!/usr/bin/env python3
"""Paired ABBA analysis for *measured* wall-times. No fabricated measurements.

Input CSV columns: scenario,block,variant,ns; one or more A/B measurements per block.
Returns median paired speedup A/B and a percentile bootstrap CI across *blocks*.
This is illustrative statistics: it does not cure biased sampling or noise.
"""
import argparse
import csv
import math
import random
import statistics
from collections import defaultdict


def percentile(data, fraction):
    ordered = sorted(data)
    x = (len(ordered) - 1) * fraction
    left = math.floor(x)
    right = math.ceil(x)
    return ordered[left] * (right - x) + ordered[right] * (x - left) if left != right else ordered[left]


def analyze(path, iterations, seed):
    samples = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    with open(path, newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        if not reader.fieldnames or not {'scenario', 'block', 'variant', 'ns'}.issubset(reader.fieldnames):
            raise ValueError('missing CSV columns: scenario,block,variant,ns')
        for row in reader:
            scenario = row['scenario'].strip()
            block = row['block'].strip()
            variant = row['variant'].strip().upper()
            if not scenario or not block or variant not in ('A', 'B'):
                raise ValueError(f'invalid scenario/block/variant: {row!r}')
            ns = float(row['ns'])
            if not math.isfinite(ns) or ns <= 0:
                raise ValueError(f'ns must be finite and positive: {row!r}')
            samples[scenario][block][variant].append(ns)

    rng = random.Random(seed)
    output = []
    for scenario in sorted(samples):
        log_ratios = []
        for block, variants in samples[scenario].items():
            if not variants['A'] or not variants['B']:
                raise ValueError(f'{scenario}/{block}: incomplete A/B block')
            a = statistics.median(variants['A'])
            b = statistics.median(variants['B'])
            log_ratios.append(math.log(a / b))
        if not log_ratios:
            continue
        estimate = statistics.median(log_ratios)
        bootstrap = [statistics.median(rng.choices(log_ratios, k=len(log_ratios)))
                     for _ in range(iterations)]
        lo = math.exp(percentile(bootstrap, 0.025))
        hi = math.exp(percentile(bootstrap, 0.975))
        speedup = math.exp(estimate)
        output.append((scenario, len(log_ratios), speedup, lo, hi))
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('csv_file')
    parser.add_argument('--iterations', type=int, default=10000)
    parser.add_argument('--seed', type=int, default=20261109)
    args = parser.parse_args()
    if args.iterations < 100:
        parser.error('--iterations must be >= 100')
    for scenario, count, speedup, lo, hi in analyze(args.csv_file, args.iterations, args.seed):
        status = ('uncertain' if lo <= 1.0 <= hi or count < 10 else
                  'B faster' if lo > 1.0 else 'B slower')
        print(f'{scenario}: blocks={count}, median(A/B)={speedup:.4f}, '
              f'bootstrap-95%=[{lo:.4f}, {hi:.4f}], {status}')
        if count < 10:
            print('  Warning: fewer than 10 independent paired blocks; this is exploratory.')


if __name__ == '__main__':
    main()
