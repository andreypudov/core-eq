#!/usr/bin/env python3
"""Benchmark the production Swift solver against revision-pinned published AutoEq results.

No Python packages required. Downloads only GitHub files; never calls autoeq.app.
Data and compiled tools stay in the requested cache directory, outside the repository.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', help='40-character upstream AutoEq commit SHA')
    parser.add_argument('--cases', type=Path, help='JSON regression manifest with revision, paths and per-case RMS tolerances')
    parser.add_argument('--max-import-distortion', type=float, help='fail if published text changes on import by more than this RMS in dB')
    parser.add_argument('--max-rms', type=float, help='fail cases exceeding this 20 Hz–6 kHz upstream-response RMS tolerance in dB')
    parser.add_argument('--limit', type=int, default=20, help='maximum variants; 0 means entire catalog')
    parser.add_argument('--spread', action='store_true', help='sample evenly across matching catalog entries instead of the first entries')
    parser.add_argument('--model', default='', help='case-insensitive model substring')
    parser.add_argument('--source', default='', help='measurement source substring')
    parser.add_argument('--cache', type=Path, default=Path(tempfile.gettempdir()) / 'coreeq-autoeq-benchmark')
    parser.add_argument('--output', type=Path, help='optional CSV report destination')
    args = parser.parse_args()
    cases = {}
    if args.cases:
        manifest = json.loads(args.cases.read_text())
        if args.revision and args.revision != manifest['revision']:
            parser.error('explicit revision differs from regression manifest')
        args.revision = manifest['revision']
        cases = {case['path']: float(case['max_rms_db']) for case in manifest['cases']}
        if not cases or any(not (0 < tolerance < 100) for tolerance in cases.values()):
            parser.error('regression cases must have positive, finite RMS tolerances')
    if not args.revision or not re.fullmatch('[0-9a-f]{40}', args.revision) or args.limit < 0:
        parser.error('revision must be a lowercase 40-character SHA and limit must be nonnegative')
    if args.max_rms is not None and not (0 < args.max_rms < 100):
        parser.error('max-rms must be positive and finite')
    if args.max_import_distortion is not None and not (0 <= args.max_import_distortion < 100):
        parser.error('max-import-distortion must be nonnegative and finite')
    args.cache.mkdir(parents=True, exist_ok=True)

    def download(path):
        destination = args.cache / args.revision / hashlib.sha256(path.encode()).hexdigest()
        if not destination.exists():
            url = 'https://raw.githubusercontent.com/jaakkopasanen/AutoEq/' + args.revision + '/' + urllib.parse.quote(path, safe='/')
            request = urllib.request.Request(url, headers={'User-Agent': 'CoreEQ-dev-benchmark'})
            with urllib.request.urlopen(request, timeout=60) as response:
                data = response.read()
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary = destination.with_suffix('.partial')
            temporary.write_bytes(data)
            temporary.replace(destination)
        return destination

    sources = [
        'Tools/AutoEQCompare.swift', 'CoreEQ/Presets/AutoEQ/AutoEQLocalSolver.swift',
        'CoreEQ/Presets/AutoEQ/AutoEQModels.swift', 'CoreEQ/Presets/AutoEQ/AutoEQProfileBuilder.swift',
        'CoreEQ/EQ/Biquad.swift', 'CoreEQ/Presets/EQFilter.swift', 'CoreEQ/Presets/EQProfile.swift',
        'CoreEQ/Presets/BuiltInProfiles.swift', 'CoreEQ/Presets/FilterChain.swift',
        'CoreEQ/Presets/ImportDisclosure.swift', 'CoreEQ/Presets/QuickTone.swift',
        'CoreEQ/Presets/ParametricEQParser.swift',
        'CoreEQ/Presets/ParametricEQSerializer.swift', 'CoreEQ/Extensions/Double+Clamped.swift',
    ]
    binary = args.cache / 'autoeq-compare'
    module_cache = args.cache / 'swift-module-cache'
    module_cache.mkdir(exist_ok=True)
    subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-module-cache-path', str(module_cache), '-o', str(binary)] +
                   [str(ROOT / source) for source in sources], check=True)
    index = download('results/INDEX.md').read_text()
    paths = []
    for line in index.splitlines():
        match = re.match(r'- \[.*\]\(\./(.*)\) by ', line)
        if not match:
            continue
        path = urllib.parse.unquote(match.group(1))
        parts = path.split('/')
        if len(parts) != 3 or 'crinacle' in parts[0].lower():
            continue
        if args.model.lower() not in parts[2].lower() or args.source.lower() not in parts[0].lower():
            continue
        if path not in paths:
            paths.append(path)
    if cases:
        missing = set(cases) - set(paths)
        if missing:
            parser.error('regression cases missing from supported catalog: ' + ', '.join(sorted(missing)))
        paths = list(cases)
    # Keep deterministic catalog order; every result identifies its source and pinned revision.
    if not cases and args.limit and len(paths) > args.limit:
        if args.spread and args.limit > 1:
            paths = [paths[round(i * (len(paths) - 1) / (args.limit - 1))] for i in range(args.limit)]
        else:
            paths = paths[:args.limit]
    if not paths:
        parser.error('no matching supported variants')
    rows = []
    failures = 0
    for i, path in enumerate(paths, 1):
        model = path.split('/')[-1]
        row = {'revision': args.revision, 'path': path}
        try:
            measurement = download(f'results/{path}/{model}.csv')
            published = download(f'results/{path}/{model} ParametricEQ.txt')
            result = subprocess.run([str(binary), str(measurement), str(published)],
                                    check=True, capture_output=True, text=True)
            row.update(json.loads(result.stdout))
            row['error'] = ''
            if args.max_import_distortion is not None:
                if row['published_import_distortion_rms_20_6000_db'] > args.max_import_distortion or abs(row['published_preamp_import_error_db']) > args.max_import_distortion:
                    raise ValueError('published correction changed during import')
            tolerance = cases.get(path, args.max_rms)
            if tolerance is not None:
                row['max_rms_db'] = tolerance
                if row['rms_20_6000_db'] > tolerance:
                    raise ValueError(f'RMS {row["rms_20_6000_db"]:.3f} exceeds {tolerance:.3f} dB tolerance')
                if not -12 <= row['local_preamp_db'] <= 0:
                    raise ValueError('computed preamp outside CoreEQ range')
                if row['headroom_db'] > -0.19 or row['max_absolute_filter_gain_db'] > 12:
                    raise ValueError('computed headroom or filter gain constraint failed')
            print(f'[{i}/{len(paths)}] {path}: RMS {row["rms_20_6000_db"]:.3f} dB', file=sys.stderr)
        except Exception as error:
            row['error'] = str(error)
            failures += 1
            print(f'[{i}/{len(paths)}] {path}: ERROR {error}', file=sys.stderr)
        rows.append(row)
    fields = list(dict.fromkeys(key for row in rows for key in row))
    output = args.output.open('w', newline='') if args.output else sys.stdout
    try:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    finally:
        if args.output:
            output.close()
    print(f'{len(rows) - failures} succeeded; {failures} failed; revision {args.revision}', file=sys.stderr)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
