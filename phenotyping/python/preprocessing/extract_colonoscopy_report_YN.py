#!/usr/bin/env python3
"""
extract_colonoscopy_report_YN.py -- inputs for the `colonoscopy_report_yn` gate.

One input per candidate note. gemma-4-26-A4 answers Yes/No to "is this a colonoscopy
procedure report", and the Yes IDs become the whitelist that extract_colonoscopy_event.py
reads with --whitelist.

A model gate rather than a TIU document-title whitelist on purpose: titles drift over time
and differ by station, so a title rule does not port to another site, while the note body
does.

The regex below is a PREFILTER, not the gate. It asks only whether a note could possibly be
a lower-endoscopy report -- does it name the procedure at all -- which drops the bulk of the
full-text-search corpus (notes that matched on "colitis" or "mesalamine" alone) without
making any report-vs-mention judgment. That judgment is the model's, which is the entire
point of the gate, so the prefilter is deliberately recall-favoring and imposes no structure
requirement.

Truncation is head+tail: a report announces itself in its first lines (title, procedure,
indication) and closes with the impression; the middle is what is expendable.

Newlines are escaped to a literal backslash-n because data-extraction.cpp splits --file on
'\n' (one record per line) and calls convertEscapedNewlines() on each record itself.

    ./extract_colonoscopy_report_YN.py --buckets /data/note_buckets \
        --out-dir /data/models/inputs/colonoscopy_report_yn
"""
import argparse
import re
import sys
from pathlib import Path

from snippet_lib import _iter_buckets, _iter_single_csv, _parse_dt

# Names any lower endoscopy. No structure cues and no negative lookarounds: a note that only
# PLANS a colonoscopy still reaches the model, which is what we want it deciding.
PREFILTER = re.compile(
    r"(?i)\b(?:colonoscop\w*|sigmoidoscop\w*|pouchoscop\w*|chromoendoscop\w*|"
    r"lower\s+endoscopy|flex(?:ible)?\s+sig\w*)"
)


def _head_tail(text, budget):
    """Keep the head and the tail. A report identifies itself in its opening lines and closes
    with the impression, so a plain head cut is the one truncation that reliably loses the
    signal the gate is looking for."""
    if len(text) <= budget:
        return text
    head = budget * 2 // 3
    tail = budget - head
    return text[:head] + "\n[...truncated...]\n" + text[-tail:]


def main():
    ap = argparse.ArgumentParser(description="Build colonoscopy_report_yn gate inputs.")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--buckets", help="dir of bucket_*.csv.gz note buckets")
    src.add_argument("--notes", help="single notes CSV")
    ap.add_argument("--out-dir", default="colonoscopy_report_yn_inputs")
    ap.add_argument("--max-chars", type=int, default=4000,
                    help="head+tail budget per note. This is the throughput knob: the system "
                         "prompt is prefilled once and shared across sequences, so cost is "
                         "note tokens alone. A report identifies itself in its opening lines "
                         "and its impression, so this can go lower if the corpus demands it.")
    args = ap.parse_args()

    outdir = Path(args.out_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    # Always replicate 1: a yes/no gate has nothing to subsample, so every model reads the
    # same file. The _1 suffix is what run_one.sh looks for, so this drops into jobs.conf as
    # an ordinary row.
    in_w = (outdir / "inputs_1.txt").open("w", encoding="utf-8")
    id_w = (outdir / "IDs_1.txt").open("w", encoding="utf-8")

    source = _iter_buckets(Path(args.buckets)) if args.buckets else _iter_single_csv(Path(args.notes))
    n_seen = n_kept = 0
    for _, rows in source:
        for row in rows:
            n_seen += 1
            if not PREFILTER.search(row["ReportText"]):
                continue
            dt = _parse_dt(row["NoteDateTime"])
            body = "\n".join([
                f"Note date: {dt.date().isoformat() if dt else 'Unknown'}",
                _head_tail(row["ReportText"], args.max_chars),
            ])
            line = body.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\\n")
            in_w.write(line + "\n")
            id_w.write((row["NoteID"] or "") + "\n")
            n_kept += 1

    in_w.close()
    id_w.close()
    print(f"[colonoscopy_report_yn] {n_kept:,} candidate notes of {n_seen:,} seen "
          f"({100.0 * n_kept / max(n_seen, 1):.1f}%) -> {outdir}", file=sys.stderr)


if __name__ == "__main__":
    main()
