#!/usr/bin/env python3
"""
extract_colonoscopy_event.py -- one model input per COLONOSCOPY EVENT.

The unit is the procedure, not the note and not the pathology report. An event is
assembled from up to three independent sources, any of which may be missing:

  * a colonoscopy procedure report  (note buckets, body-regex gated)
  * colonoscopy CPT codes           (--cpt-csv:  PatientICN, CPT_date)
  * colorectal pathology reports    (--path-csv: one row per SurgicalPathologySID)

Keying on pathology drops every clean exam with no biopsy, and those exams are the
denominators for surveillance interval and exposure time. Keying on the event keeps
CPT-without-path and path-without-CPT as ordinary rows.

Clustering, per patient:
  1. Procedure evidence = gated note dates + CPT dates. Sort, then sweep into clusters,
     starting a new cluster when the gap exceeds --merge-days. One cluster = one event.
     Its anchor is the earliest note date in the cluster, else the earliest CPT date --
     a note is written at the procedure, a CPT code is billed around it.
  2. Each pathology report attaches to the nearest anchor within --link-days, ties
     broken toward SpecimenTakenDate >= anchor (specimens are taken at or after the
     procedure). Attachment is many-to-one, so nearest-first is optimal per report and
     no global assignment step is needed.
  3. Pathology with no event in range seeds path-only events (external or unbilled
     procedures), swept with --merge-days so several jars from one procedure stay one
     event.

Every event is emitted, exam-only ones included. Each input carries a SOURCES header so
the model can separate "the report is silent on prep" from "there is no report" -- these
are opposite facts downstream and both otherwise arrive as "unknown".

Newlines are escaped to a literal backslash-n: data-extraction.cpp splits --file on '\n'
(one record per line) and calls convertEscapedNewlines() on each record itself.

    ./extract_colonoscopy_event.py --buckets /data/note_buckets \
        --path-csv /data/path/colo_path_reports.csv.gz \
        --cpt-csv  /data/path/colonoscopy_cpt_dates.csv \
        --out-dir  /data/models/inputs/colonoscopy_event
"""
import argparse
import csv
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Optional

from snippet_lib import _iter_buckets, _iter_single_csv, _open_maybe_gzip, _parse_dt

# A note is a procedure report if it names the procedure AND carries report structure.
# Sigmoidoscopy is included: IBD surveillance sigmoidoscopies yield the same dysplasia and
# colitis-extent findings. Drop the alternation to restrict to colonoscopy only.
GATE_PROC = re.compile(r"(?i)\b(?:colonoscop\w*|sigmoidoscop\w*)")
GATE_STRUCTURE = re.compile(
    r"(?i)(?:findings?:|impression:|procedure:|indication:|"
    r"scope\s+(?:was\s+)?(?:inserted|advanced)|terminal\s+ileum|"
    r"cecum|withdrawal|bowel\s+prep|prep\s+quality|retroflex|"
    r"mayo\s+(?:score|endoscopic)|boston\s+bowel)"
)

# A linked TIU note shorter than this fraction of the reconstructed domain text is an
# addendum stub, not a full report. See _build_path_index.
ADDENDUM_RATIO = 0.5

# Section labels emitted by the pathology SQL. Ordered least- to most-informative for the
# extraction, which is the order _fit_path_text sheds them under budget pressure.
PATH_SECTIONS = [
    "GROSS DESCRIPTION:",
    "SPECIMENS:",
    "SUPPLEMENT:",
    "COMMENT:",
    "MICROSCOPIC DESCRIPTION:",
    "DIAGNOSIS:",
]


@dataclass
class Event:
    anchor: date
    notes: list = field(default_factory=list)      # bucket rows for gated procedure reports
    cpt_dates: list = field(default_factory=list)
    paths: list = field(default_factory=list)      # (offset_days, path_index_entry)


@dataclass
class PathEntry:
    sid: str
    taken: date
    offset: int          # byte offset into the scratch JSONL
    tiu_sids: str
    source: str          # "tiu" or "domain" -- which text won, recorded for auditing


def _sweep(dates, gap_days):
    """Group a sorted date list into clusters, breaking whenever the gap to the previous
    date exceeds gap_days. Yields lists of (date, payload). Single-linkage can in principle
    chain, but real procedure dates sit weeks apart, so a 3-day gap never bridges two
    exams; the run summary reports any cluster spanning > 4 * gap_days as an audit flag."""
    cluster = []
    prev = None
    for d, payload in dates:
        if prev is not None and (d - prev).days > gap_days:
            yield cluster
            cluster = []
        cluster.append((d, payload))
        prev = d
    if cluster:
        yield cluster


def _build_path_index(path_csv: Path, scratch: Path):
    """Stream the pathology CSV once, writing the chosen report text to a scratch JSONL and
    keeping only a light index in RAM (~80 bytes/report). The bucket loop then seeks by byte
    offset, so the full corpus of nvarchar(max) report text is never resident."""
    index = defaultdict(list)
    by_source = defaultdict(int)
    n_rows = 0
    with _open_maybe_gzip(path_csv) as f, scratch.open("wb") as out:
        reader = csv.DictReader(f)
        cols = {c.lower(): c for c in (reader.fieldnames or [])}
        need = ("surgicalpathologysid", "patienticn", "specimentakendate")
        missing = [c for c in need if c not in cols]
        if missing:
            raise SystemExit(f"{path_csv}: missing column(s) {missing}; got {reader.fieldnames}")
        c_sid, c_icn = cols["surgicalpathologysid"], cols["patienticn"]
        c_date = cols["specimentakendate"]
        # PathReportText is the R export's already-resolved column (it picks the longer of the
        # signed note and the reconstructed domain text). Raw TIUReportText/PathDomainText are
        # still accepted so an unresolved export works too.
        c_txt = cols.get("pathreporttext")
        c_tiu_txt = cols.get("tiureporttext")
        c_dom_txt = cols.get("pathdomaintext")
        c_tiu_sid = (cols.get("pathtiudocumentsid") or cols.get("pathtiudocumentsids")
                     or cols.get("tiudocumentsid"))
        if not (c_txt or c_tiu_txt or c_dom_txt):
            raise SystemExit(f"{path_csv}: need PathReportText, or TIUReportText/PathDomainText")

        offset = 0
        for row in reader:
            taken = _parse_dt(row[c_date])
            if taken is None:
                continue                      # no date means it cannot be placed on the spine
            if c_txt:
                text, source = (row.get(c_txt) or "").strip(), "resolved"
            else:
                tiu = (row.get(c_tiu_txt) or "").strip() if c_tiu_txt else ""
                dom = (row.get(c_dom_txt) or "").strip() if c_dom_txt else ""
                # The signed TIU note is the real report, but the SQL keeps only the LATEST
                # note per accession and a VA addendum often carries just the added text rather
                # than a restatement. A TIU note far shorter than the reconstructed domain text
                # is treated as an addendum and appended, never substituted.
                if tiu and dom and len(tiu) < len(dom) * ADDENDUM_RATIO:
                    text = dom + "\n\nADDENDUM (latest linked note):\n" + tiu
                    source = "domain+addendum"
                elif tiu:
                    text, source = tiu, "tiu"
                else:
                    text, source = dom, "domain"
            if not text:
                continue
            blob = json.dumps({"sid": row[c_sid], "text": text}).encode("utf-8") + b"\n"
            out.write(blob)
            index[row[c_icn]].append(PathEntry(
                sid=row[c_sid], taken=taken.date(), offset=offset,
                tiu_sids=(row.get(c_tiu_sid) or "") if c_tiu_sid else "", source=source))
            offset += len(blob)
            n_rows += 1
            by_source[source] += 1
    print(f"[colonoscopy_event] indexed {n_rows:,} pathology reports "
          f"({', '.join(f'{v:,} {k}' for k, v in sorted(by_source.items()))}) "
          f"for {len(index):,} patients", file=sys.stderr)
    return index


def _read_cpt(cpt_csv: Path):
    """PatientICN -> sorted list of distinct CPT dates."""
    by_pt = defaultdict(set)
    with _open_maybe_gzip(cpt_csv) as f:
        reader = csv.DictReader(f)
        cols = {c.lower(): c for c in (reader.fieldnames or [])}
        c_icn = cols.get("patienticn") or cols.get("patientid")
        c_date = cols.get("cpt_date") or cols.get("procdate")
        if not (c_icn and c_date):
            raise SystemExit(f"{cpt_csv}: need PatientICN and CPT_date; got {reader.fieldnames}")
        for row in reader:
            dt = _parse_dt(row[c_date])
            if dt:
                by_pt[row[c_icn]].add(dt.date())
    print(f"[colonoscopy_event] read CPT dates for {len(by_pt):,} patients", file=sys.stderr)
    return {k: sorted(v) for k, v in by_pt.items()}


def cluster_patient(notes, cpt_dates, path_entries, merge_days, link_days):
    """Return the patient's events, ordered by anchor date. See the module docstring for the
    three stages; this is the whole of the linkage logic and the only place it lives."""
    evidence = [(_parse_dt(r["NoteDateTime"]).date(), ("note", r)) for r in notes]
    evidence += [(d, ("cpt", d)) for d in cpt_dates]
    evidence.sort(key=lambda x: x[0])

    events = []
    for cluster in _sweep(evidence, merge_days):
        ev = Event(anchor=cluster[0][0])
        for d, (kind, payload) in cluster:
            (ev.notes if kind == "note" else ev.cpt_dates).append(payload)
        if ev.notes:
            # A note dates the procedure better than a billing code, so re-anchor on it.
            ev.anchor = min(_parse_dt(r["NoteDateTime"]).date() for r in ev.notes)
        events.append(ev)

    orphans = []
    for pe in path_entries:
        near = [(abs((pe.taken - e.anchor).days), pe.taken < e.anchor, e) for e in events]
        near = [c for c in near if c[0] <= link_days]
        if not near:
            orphans.append(pe)
            continue
        # Nearest anchor wins; a tie goes to the event the specimen FOLLOWS, since tissue is
        # taken at or after the procedure, never before it.
        delta, _, ev = min(near, key=lambda c: (c[0], c[1]))
        ev.paths.append((int((pe.taken - ev.anchor).days), pe))

    # Pathology with no procedure evidence at all: an external or unbilled colonoscopy. Sweep
    # so several jars resulted from one procedure stay one event rather than N events.
    for cluster in _sweep(sorted(((pe.taken, pe) for pe in orphans), key=lambda x: x[0]),
                          merge_days):
        ev = Event(anchor=cluster[0][0])
        ev.paths = [(int((pe.taken - ev.anchor).days), pe) for _, pe in cluster]
        events.append(ev)

    events.sort(key=lambda e: e.anchor)
    return events


def _head_tail(text, budget):
    """Keep the head and the tail. Colonoscopy reports put Impression last and pathology puts
    Diagnosis last, so a plain head cut is the one truncation that reliably loses the answer."""
    if len(text) <= budget:
        return text
    head = budget * 2 // 3
    tail = budget - head
    return text[:head] + "\n[...truncated...]\n" + text[-tail:]


def _fit_path_text(text, budget):
    """Trim a pathology report to budget by shedding whole sections in PATH_SECTIONS order,
    so Diagnosis / Microscopic / Comment survive intact. Reconstructed PathDomainText carries
    the labels the SQL wrote; a signed TIU note does not, and falls through to head+tail."""
    if len(text) <= budget:
        return text
    spans = [(text.find(lab), lab) for lab in PATH_SECTIONS]
    spans = sorted((pos, lab) for pos, lab in spans if pos >= 0)
    if len(spans) < 2:
        return _head_tail(text, budget)
    bounds = {}
    for i, (pos, lab) in enumerate(spans):
        end = spans[i + 1][0] if i + 1 < len(spans) else len(text)
        bounds[lab] = (pos, end)
    keep = dict(bounds)
    for lab in PATH_SECTIONS:               # least-informative first
        if sum(e - s for s, e in keep.values()) <= budget:
            break
        if len(keep) > 1:
            keep.pop(lab, None)
    out = "".join(text[s:e] for s, e in sorted(keep.values()))
    return _head_tail(out, budget)


def build_input(icn, ev, scratch_fh, args):
    """Render one event as the model input. Order is deliberate: SOURCES first so the model
    fixes what is and is not available before reading anything, then the procedure report,
    then pathology."""
    n_paths = len(ev.paths)
    parts = [
        "SOURCES: "
        f"colonoscopy report: {'yes (%d)' % len(ev.notes) if ev.notes else 'NONE'} | "
        f"pathology reports: {n_paths if n_paths else 'NONE'} | "
        f"CPT date: {', '.join(d.isoformat() for d in ev.cpt_dates) if ev.cpt_dates else 'NONE'}",
        f"Event date: {ev.anchor.isoformat()}",
    ]
    for row in ev.notes:
        dt = _parse_dt(row["NoteDateTime"])
        parts += ["", "<<< COLONOSCOPY REPORT >>>",
                  f"Report date: {dt.date().isoformat()}",
                  _head_tail(row["ReportText"], args.max_note_chars)]
    for i, (delta, pe) in enumerate(sorted(ev.paths, key=lambda p: (abs(p[0]), p[1].sid)), 1):
        scratch_fh.seek(pe.offset)
        text = json.loads(scratch_fh.readline().decode("utf-8"))["text"]
        parts += ["", f"<<< PATHOLOGY REPORT {i} of {n_paths} >>>",
                  f"Specimen taken date: {pe.taken.isoformat()} "
                  f"({delta:+d} days from event date)",
                  _fit_path_text(text, args.max_path_chars)]
    body = "\n".join(parts)
    return _head_tail(body, args.max_chars).replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\\n")


def main():
    ap = argparse.ArgumentParser(description="Build one input per colonoscopy event.")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--buckets", help="dir of bucket_*.csv.gz note buckets")
    src.add_argument("--notes", help="single notes CSV")
    ap.add_argument("--path-csv", required=True, help="one row per SurgicalPathologySID")
    ap.add_argument("--cpt-csv", required=True, help="PatientICN, CPT_date")
    ap.add_argument("--out-dir", default="colonoscopy_event_inputs")
    ap.add_argument("--scratch-dir", default=None, help="defaults to --out-dir")
    ap.add_argument("--whitelist", default=None,
                    help="file of note IDs the colonoscopy_report_yn gate answered Yes for; "
                         "without it the GATE_PROC/GATE_STRUCTURE regex is used instead")
    ap.add_argument("--replicates", type=int, default=1,
                    help="identical copies; report-level inputs have nothing to subsample")
    ap.add_argument("--merge-days", type=int, default=3,
                    help="gap above which procedure evidence starts a new event")
    ap.add_argument("--link-days", type=int, default=30,
                    help="max |specimen date - event anchor| for attachment")
    ap.add_argument("--max-note-chars", type=int, default=30000)
    ap.add_argument("--max-path-chars", type=int, default=25000)
    ap.add_argument("--max-chars", type=int, default=90000)
    args = ap.parse_args()

    outdir = Path(args.out_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    scratch = Path(args.scratch_dir or args.out_dir) / "path_text.jsonl"
    scratch.parent.mkdir(parents=True, exist_ok=True)

    path_index = _build_path_index(Path(args.path_csv), scratch)
    cpt_index = _read_cpt(Path(args.cpt_csv))

    n_reps = args.replicates
    in_w = [(outdir / f"inputs_{r + 1}.txt").open("w", encoding="utf-8") for r in range(n_reps)]
    id_w = [(outdir / f"IDs_{r + 1}.txt").open("w", encoding="utf-8") for r in range(n_reps)]
    man_f = (outdir / "manifest.csv").open("w", encoding="utf-8", newline="")
    man = csv.writer(man_f)
    man.writerow(["event_id", "PatientICN", "event_date", "has_colo_report", "n_colo_notes",
                  "colo_note_ids", "cpt_dates", "n_path", "path_sids", "path_tiu_sids",
                  "path_offset_days", "path_text_source", "input_chars"])

    counts = defaultdict(int)

    whitelist = None
    if args.whitelist:
        with open(args.whitelist, encoding="utf-8") as f:
            whitelist = {ln.strip() for ln in f if ln.strip()}
        print(f"[colonoscopy_event] gate: whitelist of {len(whitelist):,} note IDs",
              file=sys.stderr)

    def is_report(row):
        """The model gate when a whitelist is supplied, the regex otherwise. The whitelist is
        the Yes set from the colonoscopy_report_yn job; the regex is the standalone fallback
        for running this script without that pass."""
        if whitelist is not None:
            return row["NoteID"] in whitelist
        return bool(GATE_PROC.search(row["ReportText"])
                    and GATE_STRUCTURE.search(row["ReportText"]))

    def emit(icn, events, fh):
        for seq, ev in enumerate(events, 1):
            eid = f"{icn}|{ev.anchor.strftime('%Y%m%d')}|{seq}"
            line = build_input(icn, ev, fh, args)
            for r in range(n_reps):
                in_w[r].write(line + "\n")
                id_w[r].write(eid + "\n")
            man.writerow([
                eid, icn, ev.anchor.isoformat(), int(bool(ev.notes)), len(ev.notes),
                ";".join(r["NoteID"] for r in ev.notes),
                ";".join(d.isoformat() for d in ev.cpt_dates),
                len(ev.paths), ";".join(pe.sid for _, pe in ev.paths),
                ";".join(pe.tiu_sids for _, pe in ev.paths),
                ";".join(str(d) for d, _ in ev.paths),
                ";".join(pe.source for _, pe in ev.paths), len(line)])
            counts["events"] += 1
            counts["colo+path" if ev.notes and ev.paths else
                   "colo_only" if ev.notes else
                   "path_only" if ev.paths else "cpt_only"] += 1

    source = _iter_buckets(Path(args.buckets)) if args.buckets else _iter_single_csv(Path(args.notes))
    seen = set()
    with scratch.open("rb") as fh:
        for icn, rows in source:
            seen.add(icn)
            notes = [r for r in rows if _parse_dt(r["NoteDateTime"]) and is_report(r)]
            counts["gated_notes"] += len(notes)
            paths = path_index.get(icn, [])
            cpts = cpt_index.get(icn, [])
            if not (notes or paths or cpts):
                continue
            emit(icn, cluster_patient(notes, cpts, paths, args.merge_days, args.link_days), fh)

        # Patients whose pathology or CPT rows never met a note bucket -- they still have real
        # events. Dropping them here is exactly the path-without-CPT loss we are avoiding.
        leftover = (set(path_index) | set(cpt_index)) - seen
        for icn in sorted(leftover):
            counts["patients_no_notes"] += 1
            emit(icn, cluster_patient([], cpt_index.get(icn, []), path_index.get(icn, []),
                                      args.merge_days, args.link_days), fh)

    for w in in_w + id_w:
        w.close()
    man_f.close()
    print(f"[colonoscopy_event] {counts['events']:,} events "
          f"(colo+path {counts['colo+path']:,} | colo only {counts['colo_only']:,} | "
          f"path only {counts['path_only']:,} | cpt only {counts['cpt_only']:,}) "
          f"from {counts['gated_notes']:,} gated notes; "
          f"{counts['patients_no_notes']:,} patients had no notes in the buckets. "
          f"-> {outdir}", file=sys.stderr)


if __name__ == "__main__":
    main()
