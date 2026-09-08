#!/usr/bin/env python3
"""
route_colectomy_crc.py -- route patients with a colectomy and a CRC in the same (or adjacent)
year to the colectomy_crc relationship task.

Finds patients where a colectomy surgery-year and a CRC diagnosis-year fall within --year-window
years of each other, reading BOTH tasks' LLM outputs and unioning across all three sources per
task (reviewer + two small models) -- the same recall-favoring logic as route_crohns_montreal.
For each such patient it RE-EXTRACTS a purpose-built colectomy+CRC timeline from the note buckets
(a combined concept regex over operative, cancer, and pathology vocabulary) and writes one input,
so a downstream model can classify the relationship:
  * colectomy_for_crc      -- the colectomy was performed because of a known CRC
  * crc_found_at_colectomy -- colectomy for another reason; CRC found on the specimen
  * unrelated              -- separate events (e.g. partial colectomy for IBD, later a CRC)

Year sources -- each event yields a YEAR INTERVAL, and a patient routes when a colectomy interval
overlaps a CRC interval (within --year-window years of slack). The interval is the concrete
surgery_date/diagnosis_date year, or, when that is "unknown", the date_approximate form: "during
1990s" -> that decade, "before/after YYYY" -> open-ended, "YYYY-YYYY" -> that range. Only
"unknown" with no approximate form carries no interval and cannot match.
  colectomy -- surgery_date (+ date_approximate) of each resection entry (a JSON ARRAY).
  CRC       -- diagnosis_date (+ date_approximate) when crc == "yes" (a JSON object).

    ./route_colectomy_crc.py \
        --colectomy-dirs REVIEWER SMALL1 SMALL2 \
        --crc-dirs       REVIEWER SMALL1 SMALL2 \
        --buckets /data/models/ibd_csv_data/note_buckets \
        --out-dir /data/models/inputs/colectomy_crc
"""
import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

# read_answers + the two JSON parsers are the task output-reading conventions; reuse them so this
# reads the reviewer/small-model files exactly as the consensus steps do. parse_obj pulls the
# outermost {...} (CRC, a single object); parse_arr pulls the outermost [...] (colectomy, an array).
_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))
from skip_consensus_ibd import read_answers, parse as parse_obj          # noqa: E402
from skip_consensus_colectomy import parse as parse_arr                  # noqa: E402

# snippet_lib ships with the preprocessing scripts; reuse its bucket reader and snippet pipeline
# rather than re-deriving the extraction the other tasks depend on behaving identically.
sys.path.insert(0, str(_HERE.parent / "preprocessing"))
from snippet_lib import (TaskConfig, _iter_buckets, _iter_single_csv,    # noqa: E402
                         _build_pool, _select_replicates, _stable_seed, _format)

# ---------------------------------------------------------------------------
# Combined colectomy + CRC concept vocabulary = the UNION of the two tasks' own concept regexes,
# copied verbatim so this pulls exactly the snippets either extractor would: PROC from
# extract_colectomy.py, CANCER (with its screening guard) from extract_crc.py.
# ---------------------------------------------------------------------------
_SEG    = r"(?:procto|hemi|recto\s?sigmoid|subtotal|total|segmental|partial)"
_ORGAN  = r"\b(?:colon|rect\w*|cecum|sigmoid|bowel|ileocecal)"
_REMOVE = r"(?:resect|remov|excis)\w*"
PROC = (                                                   # extract_colectomy.py
    rf"{_SEG}?\s*colectom\w*|"
    r"(?:sigmoid|proct|ileocec)ectom\w*|"
    r"abdominoperineal\s+resection|low\s+anterior\s+resection|(?-i:\bLAR\b)|"
    rf"{_ORGAN}.{{0,20}}?{_REMOVE}|{_REMOVE}.{{0,20}}?{_ORGAN}|"
    r"hartmann\w*|(?:ileostom|colostom)\w*|anastomos\w*|"
    r"j[- ]?pouch|\bipaa\b|pouch\s+(?:construction|creation)"
)
_SITE  = r"\b(?:colorectal|colon(?:ic)?|rect\w*|sigmoid|cec(?:al|um))"
_MALIG = r"(?:adenoca\w*|(?:adeno)?carcinoma|cancer|malignan\w*|neoplas)"
_NOT_SCREENING = r"(?!\s+screen)"
CANCER = (                                                 # extract_crc.py
    rf"{_SITE}.{{0,20}}?{_MALIG}{_NOT_SCREENING}|"
    rf"{_SITE}\s+ca\b{_NOT_SCREENING}|"
    rf"{_MALIG}\s+of\s+(?:the\s+)?{_SITE}|"
    rf"\bca\s+of\s+(?:the\s+)?{_SITE}|"
    rf"\bcrc\b{_NOT_SCREENING}"
)

CONFIG = TaskConfig(
    name="colectomy_crc",
    concept_regex=rf"(?i)(?:{PROC}|{CANCER})",
    # Decisive evidence for the relationship = a snippet that co-mentions cancer AND an operation
    # or specimen: that is where "resected for the tumor" vs "cancer found in the specimen" lives.
    priority_regex=(
        r"\A(?=.*(?i:cancer|carcinoma|adenocarcinoma|malignan|\bCRC\b))"
        r"(?=.*(?i:colectom|resect|specimen|patholog|indication|underwent|performed))"
    ),
    question="",
    snip_chars=300,
    max_snips_per_note=12,
    snippet_budget=40,
    char_budget=60000,
    n_recent=8,
    n_distant=8,
    priority_cap=20,
    dedup="normalized",
)


_MINY, _MAXY = 0, 9999


def _year(datestr):
    """Concrete 4-digit year from a 'YYYY[-MM[-DD]]' date field, else None."""
    s = (datestr or "").strip().strip('"')
    return int(s[:4]) if len(s) >= 4 and s[:4].isdigit() else None


def _approx_interval(approx):
    """A (lo, hi) year interval from a date_approximate string, or None. Handles the forms both
    grammars emit: "during 1990s" (a decade -> that decade), "before YYYY" (open below), "after
    YYYY" (open above), and "YYYY-YYYY" (a range). "exact"/"unknown" carry no interval of their own."""
    s = (approx or "").strip().strip('"')
    m = re.fullmatch(r"during (\d{3})0s", s)
    if m:
        d = int(m.group(1)) * 10
        return (d, d + 9)
    m = re.fullmatch(r"before (\d{4})", s)
    if m:
        return (_MINY, int(m.group(1)))
    m = re.fullmatch(r"after (\d{4})", s)
    if m:
        return (int(m.group(1)), _MAXY)
    m = re.fullmatch(r"(\d{4})-(\d{4})", s)
    if m:
        a, b = int(m.group(1)), int(m.group(2))
        return (min(a, b), max(a, b))
    return None


def _interval(datestr, approx):
    """A (lo, hi) year interval for one event: the concrete date year when present, otherwise the
    approximate form. None when neither pins a bounded year."""
    y = _year(datestr)
    if y is not None:
        return (y, y)
    return _approx_interval(approx)


def colectomy_intervals(dirs):
    """PatientID -> set of (lo, hi) surgery-year intervals across every colectomy source (union).
    Each source is a JSON array of resection entries."""
    ivals = defaultdict(set)
    for d in dirs:
        ans, _, _ = read_answers(d)
        for pid, a in ans.items():
            arr = parse_arr(a)
            if not isinstance(arr, list):
                continue
            for entry in arr:
                if isinstance(entry, dict):
                    iv = _interval(entry.get("surgery_date"), entry.get("date_approximate"))
                    if iv:
                        ivals[pid].add(iv)
    return ivals


def crc_intervals(dirs):
    """PatientID -> set of (lo, hi) CRC diagnosis-year intervals across every CRC source (union).
    Only crc=="yes" answers contribute."""
    ivals = defaultdict(set)
    for d in dirs:
        ans, _, _ = read_answers(d)
        for pid, a in ans.items():
            obj = parse_obj(a)
            if isinstance(obj, dict) and obj.get("crc") == "yes":
                iv = _interval(obj.get("diagnosis_date"), obj.get("date_approximate"))
                if iv:
                    ivals[pid].add(iv)
    return ivals


def _overlaps(a, b, window):
    """True when intervals a=(lo,hi) and b=(lo,hi) overlap, allowing `window` years of slack -- so
    same-or-adjacent points match, and a "before 1989"/"1998-2003"/decade range that touches the
    other event's interval matches too."""
    return a[0] <= b[1] + window and b[0] <= a[1] + window


def routed_ids(coly, crcy, window):
    """Patients with a colectomy interval overlapping (within `window`) a CRC interval."""
    out = set()
    for pid in set(coly) & set(crcy):
        if any(_overlaps(c, r, window) for c in coly[pid] for r in crcy[pid]):
            out.add(pid)
    return out


def main():
    ap = argparse.ArgumentParser(description="Route same-year colectomy+CRC patients to colectomy_crc.")
    ap.add_argument("--colectomy-dirs", nargs="+", required=True,
                    help="colectomy out-dirs (reviewer + the two small models)")
    ap.add_argument("--crc-dirs", nargs="+", required=True,
                    help="CRC out-dirs (reviewer + the two small models)")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--buckets", help="dir of bucket_*.csv.gz note buckets")
    src.add_argument("--notes", help="single notes CSV")
    ap.add_argument("--out-dir", required=True, help="colectomy_crc input dir to write")
    ap.add_argument("--year-window", type=int, default=1,
                    help="years of slack when testing whether a colectomy interval overlaps a CRC "
                         "interval (default 1: same or adjacent year, plus any true range overlap)")
    ap.add_argument("--dry-run", action="store_true", help="report the count, write nothing")
    args = ap.parse_args()

    coly = colectomy_intervals(args.colectomy_dirs)
    crcy = crc_intervals(args.crc_dirs)
    ids = routed_ids(coly, crcy, args.year_window)
    print(f"[colectomy_crc] colectomy patients (dated): {len(coly):,} | CRC patients (dated): "
          f"{len(crcy):,} | year-overlap (+/-{args.year_window}): {len(ids):,}", file=sys.stderr)
    if not ids:
        raise SystemExit("[colectomy_crc] no same-year colectomy+CRC patients -- nothing to route")
    if args.dry_run:
        print(f"[colectomy_crc] dry run: would route {len(ids):,} patients", file=sys.stderr)
        return

    cfg = CONFIG.compile()
    outdir = Path(args.out_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    source = _iter_buckets(Path(args.buckets)) if args.buckets else _iter_single_csv(Path(args.notes))
    n_kept = n_nosnip = 0
    with (outdir / "inputs_1.txt").open("w", encoding="utf-8") as in_w, \
         (outdir / "IDs_1.txt").open("w", encoding="utf-8") as id_w:
        for pid, rows in source:
            if pid not in ids:
                continue
            pool = _build_pool(rows, cfg)
            if not pool:
                n_nosnip += 1                    # routed by year but no colectomy/CRC snippet in notes
                continue
            recs = _select_replicates(pool, cfg, 1, _stable_seed(pid, 0))[0]
            in_w.write(_format(recs, cfg, pool) + "\n")
            id_w.write(pid + "\n")
            n_kept += 1
    missing = len(ids) - n_kept - n_nosnip
    print(f"[colectomy_crc] {n_kept:,} inputs written -> {outdir} "
          f"({n_nosnip:,} routed but no matching snippet"
          + (f", {missing:,} routed but absent from the buckets" if missing else "") + ")",
          file=sys.stderr)


if __name__ == "__main__":
    main()
