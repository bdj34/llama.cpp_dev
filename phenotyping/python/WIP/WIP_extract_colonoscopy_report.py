#!/usr/bin/env python3
"""
extract_colonoscopy_report.py -- inputs for the consolidated `colonoscopy_report` task.

This is the "big consolidation": one findings task over VA colonoscopy reports (+ their
linked pathology) that downstream runs the six folded grammars as separate passes
(coloReport_unlinked, dysplasiaClassifier, colo_path_linked, completenessOfResection,
histologic_colitis, pips_strictures_tubular_colon). All six read the SAME report input;
they differ only by grammar + system prompt, so preprocessing produces one input per
colonoscopy report and the queue fans it out across passes/models.

Unit of work = one colonoscopy REPORT (not one patient). Reasons:
  * The grammars extract structured findings tied to a single procedure/specimen.
  * A report is short enough to pass whole, so there is nothing to subsample -- the
    three replicate files are therefore IDENTICAL and consensus is three models over
    the same report. (Subsampling a structured report would corrupt field extraction.)

Gate: a note is treated as a colonoscopy report if it names a colonoscopy AND carries
report structure (findings/impression/procedure/scope/prep/landmark cues). This is the
regex approximation of the old LLM yes/no gate (step 9); tighten GATE_STRUCTURE if too
many progress notes slip through.

Pathology linkage: for each report we append, best-effort, the text of the same
patient's pathology-looking notes within +/- LINK_DAYS. Because the v2 buckets are
grouped per patient, this needs no SQL. If a bucket has no pathology notes, reports are
emitted unlinked (still valid for the endoscopic-findings grammars). Disable with
--no-link-pathology.

    ./extract_colonoscopy_report.py --buckets /data/note_buckets \
        --out-dir /data/colonoscopy_report/raw_inputs
"""
import argparse
import re
import sys
from datetime import timedelta
from pathlib import Path

from snippet_lib import _iter_buckets, _iter_single_csv, _parse_dt

LINK_DAYS = 30
MAX_INPUT_CHARS = 60000   # truncate pathological mega-notes (rare) to keep ctx sane

GATE_COLO = re.compile(r"(?i)colonoscop\w*")
GATE_STRUCTURE = re.compile(
    r"(?i)(?:findings?:|impression:|procedure:|indication:|"
    r"scope\s+(?:was\s+)?(?:inserted|advanced)|terminal\s+ileum|"
    r"cecum|withdrawal|bowel\s+prep|prep\s+quality|retroflex|"
    r"mayo\s+(?:score|endoscopic)|boston\s+bowel)"
)
PATHOLOGY = re.compile(
    r"(?i)(?:specimen|microscopic|gross\s+description|"
    r"(?:final\s+)?(?:path\w*\s+)?diagnosis:|histolog\w*|"
    r"adenocarcinoma|dysplasia|adenoma|biops\w*)"
)
PATH_SITE = re.compile(r"(?i)colon|rect(?:um|al)|cecum|sigmoid|ileum|colonic")


def _escape(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if len(text) > MAX_INPUT_CHARS:
        text = text[:MAX_INPUT_CHARS] + "\n[...truncated...]"
    return text.replace("\n", "\\n")


def _is_colo_report(text: str) -> bool:
    return bool(GATE_COLO.search(text) and GATE_STRUCTURE.search(text))


def _is_pathology(text: str) -> bool:
    return bool(PATHOLOGY.search(text) and PATH_SITE.search(text))


def _build_report_input(colo_row, path_rows, link: bool) -> str:
    colo_dt = _parse_dt(colo_row["NoteDateTime"])
    parts = [
        "<<< COLONOSCOPY REPORT >>>",
        f"Report date: {colo_dt.strftime('%Y-%m-%d') if colo_dt else 'Unknown'}",
        colo_row["ReportText"],
    ]
    if link and colo_dt:
        linked = []
        for pr in path_rows:
            pdt = _parse_dt(pr["NoteDateTime"])
            if pdt and abs((pdt - colo_dt).days) <= LINK_DAYS:
                linked.append((abs((pdt - colo_dt).days), pdt, pr))
        for _, pdt, pr in sorted(linked, key=lambda x: x[0]):
            parts += [
                "",
                "<<< LINKED PATHOLOGY REPORT >>>",
                f"Pathology date: {pdt.strftime('%Y-%m-%d')}",
                pr["ReportText"],
            ]
    return "\n".join(parts)


def main():
    ap = argparse.ArgumentParser(description="Build colonoscopy_report inputs.")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--buckets", help="dir of v2 bucket_*.csv.gz")
    src.add_argument("--notes", help="single notes CSV")
    ap.add_argument("--out-dir", default="colonoscopy_report_inputs")
    ap.add_argument("--replicates", type=int, default=3)
    ap.add_argument("--no-link-pathology", action="store_true",
                    help="do not append same-patient pathology reports")
    args = ap.parse_args()

    outdir = Path(args.out_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    n_reps = args.replicates
    in_w = [(outdir / f"input_{r + 1}.txt").open("w", encoding="utf-8") for r in range(n_reps)]
    id_w = [(outdir / f"ptIDs_{r + 1}.txt").open("w", encoding="utf-8") for r in range(n_reps)]

    source = _iter_buckets(Path(args.buckets)) if args.buckets else _iter_single_csv(Path(args.notes))
    n_reports = 0
    for pid, rows in source:
        path_rows = [] if args.no_link_pathology else [r for r in rows if _is_pathology(r["ReportText"])]
        for row in rows:
            if not _is_colo_report(row["ReportText"]):
                continue
            line = _escape(_build_report_input(row, path_rows, not args.no_link_pathology))
            rid = row["NoteID"] or pid
            for r in range(n_reps):
                in_w[r].write(line + "\n")
                id_w[r].write(f"{rid}\n")
            n_reports += 1

    for w in in_w + id_w:
        w.close()
    print(f"[colonoscopy_report] wrote {n_reps} identical replicate files "
          f"({n_reports} reports) to {outdir}", file=sys.stderr)


if __name__ == "__main__":
    main()
