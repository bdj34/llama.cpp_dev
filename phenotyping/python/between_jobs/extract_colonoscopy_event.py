#!/usr/bin/env python3
"""
extract_colonoscopy_event.py -- one model input per COLONOSCOPY EVENT.

The unit is the procedure, not the note and not the pathology report. An event is
assembled from up to three independent sources, any of which may be missing:

  * colorectal pathology reports    (--path-csv: one row per SurgicalPathologySID)
  * a colonoscopy procedure report  (note buckets, gated by --whitelist)
  * colonoscopy CPT codes           (--cpt-csv:  PatientICN, CPT_date)

Keying on pathology alone drops every clean exam with no biopsy, and those exams are the
denominators for surveillance interval and exposure time. Keying on the event keeps
CPT-without-path and path-without-CPT as ordinary rows.

Anchoring, in strict priority order, all within --window-days:

  1. SpecimenTakenDate is the primary anchor. It records when tissue was taken, which is a
     fact about the procedure. Pathology dates are swept into clusters first, and those
     clusters ARE the events.
  2. Whitelisted report notes attach to the nearest pathology anchor in range, or seed
     their own events. NoteDateTime is EntryDateTime -- a SIGNING timestamp -- so it can
     lag the procedure and never overrides a specimen date.
  3. CPT dates attach last, or seed their own. Billing dates confirm that an event
     happened but never date it better than the other two.

  4. An event with no gate-confirmed report falls back to EVERY note the patient has in
     [anchor - 1 day, anchor + --window-days]: the day before through the signing lag.
     These are labeled as unconfirmed in the input so the model knows it is reading
     nearby context rather than a verified procedure report.

Nothing is truncated. A report's findings and impression are what the extraction needs and
both sit at the end, so a size cap here would silently cost accuracy; the ctx budget is set
in jobs.conf instead. Watch manifest.csv's input_chars to size it.

Every event is emitted, exam-only ones included. Each input carries a SOURCES header so the
model can separate "the report is silent on prep" from "there is no report" -- these are
opposite facts downstream and both otherwise arrive as "unknown".

Newlines are escaped to a literal backslash-n: data-extraction.cpp splits --file on '\n'
(one record per line) and calls convertEscapedNewlines() on each record itself.

    ./extract_colonoscopy_event.py --buckets /data/note_buckets \
        --path-csv  /data/path/colo_pathReports.csv.gz \
        --cpt-csv   /data/path/colo_CPT.csv.gz \
        --whitelist /data/models/inputs/colonoscopy_event/whitelist.txt \
        --out-dir   /data/models/inputs/colonoscopy_event
"""
import argparse
import csv
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, timedelta
from pathlib import Path


# snippet_lib ships with the preprocessing scripts. Import it from there rather than
# duplicating its bucket reader and date parser, both of which every task depends on
# behaving identically.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "preprocessing"))
from snippet_lib import _iter_buckets, _iter_single_csv, _open_maybe_gzip, _parse_dt  # noqa: E402

# Fallback gate, used only when --whitelist is absent so the script still runs standalone.
GATE_PROC = re.compile(r"(?i)\b(?:colonoscop\w*|sigmoidoscop\w*)")
GATE_STRUCTURE = re.compile(
    r"(?i)(?:findings?:|impression:|procedure:|indication:|"
    r"scope\s+(?:was\s+)?(?:inserted|advanced)|terminal\s+ileum|"
    r"cecum|withdrawal|bowel\s+prep|prep\s+quality|retroflex|"
    r"mayo\s+(?:score|endoscopic)|boston\s+bowel)"
)


@dataclass
class Event:
    anchor: date
    notes: list = field(default_factory=list)           # gate-confirmed procedure reports
    fallback_notes: list = field(default_factory=list)  # nearby notes, unverified
    cpt_dates: list = field(default_factory=list)
    paths: list = field(default_factory=list)           # (offset_days, PathEntry)


@dataclass
class PathEntry:
    sid: str
    taken: date
    offset: int          # byte offset into the scratch JSONL
    tiu_sid: str


def _sweep(dated, gap_days):
    """Group a sorted (date, payload) list into clusters, breaking whenever the gap to the
    previous date exceeds gap_days. Only ever applied to dates of ONE kind, so it cannot chain
    a note onto a CPT onto a specimen across a span far wider than the window."""
    cluster, prev = [], None
    for d, payload in dated:
        if prev is not None and (d - prev).days > gap_days:
            yield cluster
            cluster = []
        cluster.append((d, payload))
        prev = d
    if cluster:
        yield cluster


def _closest(rows, anchor, cap):
    """Keep at most cap notes, the ones nearest the anchor, then restore chronological order.
    A hospital stay can put 20+ notes inside the window; the nearest few are the ones that
    describe the procedure, and the rest are ward noise."""
    if len(rows) > cap:
        rows = sorted(rows, key=lambda r: abs((_parse_dt(r["NoteDateTime"]).date() - anchor).days))[:cap]
    return sorted(rows, key=lambda r: _parse_dt(r["NoteDateTime"]))


def _nearest(events, d, window):
    """The event whose anchor is closest to d within window, or None. Ties break toward the
    anchor that d FOLLOWS, since tissue is taken and notes are signed at or after a procedure,
    never before it."""
    cand = [(abs((d - e.anchor).days), d < e.anchor, e) for e in events]
    cand = [c for c in cand if c[0] <= window]
    return min(cand, key=lambda c: (c[0], c[1]))[2] if cand else None


def _build_path_index(path_csv: Path, scratch: Path):
    """Stream the pathology CSV once, writing PathReportText to a scratch JSONL and keeping
    only a light index in RAM (~80 bytes/report). The bucket loop then seeks by byte offset,
    so the full corpus of nvarchar(max) report text is never resident."""
    index = defaultdict(list)
    n_rows = 0
    with _open_maybe_gzip(path_csv) as f, scratch.open("wb") as out:
        reader = csv.DictReader(f)
        cols = {c.lower(): c for c in (reader.fieldnames or [])}
        need = ("surgicalpathologysid", "patienticn", "specimentakendate", "pathreporttext")
        missing = [c for c in need if c not in cols]
        if missing:
            raise SystemExit(f"{path_csv}: missing column(s) {missing}; got {reader.fieldnames}")
        c_sid, c_icn = cols["surgicalpathologysid"], cols["patienticn"]
        c_date, c_txt = cols["specimentakendate"], cols["pathreporttext"]
        c_tiu = cols.get("pathtiudocumentsid") or cols.get("tiudocumentsid")

        offset = 0
        for row in reader:
            taken = _parse_dt(row[c_date])
            if taken is None:
                continue                      # no date means it cannot be placed on the spine
            text = (row.get(c_txt) or "").strip()
            if not text:
                continue
            blob = json.dumps({"sid": row[c_sid], "text": text}).encode("utf-8") + b"\n"
            out.write(blob)
            index[row[c_icn]].append(PathEntry(
                sid=row[c_sid], taken=taken.date(), offset=offset,
                tiu_sid=(row.get(c_tiu) or "") if c_tiu else ""))
            offset += len(blob)
            n_rows += 1
    print(f"[colonoscopy_event] indexed {n_rows:,} pathology reports for {len(index):,} patients",
          file=sys.stderr)
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


def cluster_patient(all_notes, wl_notes, cpt_dates, path_entries, window, max_notes):
    """Return the patient's events, ordered by anchor date. This is the whole of the linkage
    logic and the only place it lives; see the module docstring for the priority order."""
    events = []

    # 1. Pathology first: SpecimenTakenDate is the most reliable date we have.
    for cluster in _sweep(sorted(((pe.taken, pe) for pe in path_entries), key=lambda x: x[0]),
                          window):
        ev = Event(anchor=cluster[0][0])
        ev.paths = [(int((pe.taken - ev.anchor).days), pe) for _, pe in cluster]
        events.append(ev)

    # 2. Gate-confirmed reports attach to a pathology anchor, or seed their own events.
    loose = []
    for r in wl_notes:
        d = _parse_dt(r["NoteDateTime"]).date()
        ev = _nearest(events, d, window)
        if ev is None:
            loose.append((d, r))
        else:
            ev.notes.append(r)
    for cluster in _sweep(sorted(loose, key=lambda x: x[0]), window):
        ev = Event(anchor=cluster[0][0])
        ev.notes = [r for _, r in cluster]
        events.append(ev)

    # 3. CPT dates last. They confirm an event happened but never date it better.
    loose = []
    for d in cpt_dates:
        ev = _nearest(events, d, window)
        if ev is None:
            loose.append((d, d))
        else:
            ev.cpt_dates.append(d)
    for cluster in _sweep(sorted(loose, key=lambda x: x[0]), window):
        ev = Event(anchor=cluster[0][0])
        ev.cpt_dates = [d for _, d in cluster]
        events.append(ev)

    # 4. No gate-confirmed report -> show every note in [anchor - 1, anchor + window]. The
    #    report may be there under a title the gate rejected, or the findings may only exist
    #    in a clinic note; either way the model gets the window rather than nothing.
    for ev in events:
        if ev.notes:
            continue
        lo, hi = ev.anchor - timedelta(days=1), ev.anchor + timedelta(days=window)
        for r in all_notes:
            d = _parse_dt(r["NoteDateTime"])
            if d and lo <= d.date() <= hi:
                ev.fallback_notes.append(r)

    for ev in events:
        ev.notes = _closest(ev.notes, ev.anchor, max_notes)
        ev.fallback_notes = _closest(ev.fallback_notes, ev.anchor, max_notes)

    events.sort(key=lambda e: e.anchor)
    return events


def build_input(ev, scratch_fh):
    """Render one event as the model input. Order is deliberate: SOURCES first so the model
    fixes what is and is not available before reading anything, then pathology (the anchor),
    then the report or the nearby notes standing in for it."""
    n_paths, n_wl, n_fb = len(ev.paths), len(ev.notes), len(ev.fallback_notes)
    if n_wl:
        report_src = f"confirmed report x{n_wl}"
    elif n_fb:
        report_src = f"NONE - {n_fb} unconfirmed note(s) from the same window shown instead"
    else:
        report_src = "NONE"
    parts = [
        f"SOURCES: colonoscopy report: {report_src} | "
        f"pathology reports: {n_paths if n_paths else 'NONE'} | "
        f"CPT date: {', '.join(d.isoformat() for d in ev.cpt_dates) if ev.cpt_dates else 'NONE'}",
        f"Event date: {ev.anchor.isoformat()}",
    ]
    for i, (delta, pe) in enumerate(sorted(ev.paths, key=lambda p: (abs(p[0]), p[1].sid)), 1):
        scratch_fh.seek(pe.offset)
        parts += ["", f"<<< PATHOLOGY REPORT {i} of {n_paths} >>>",
                  f"Specimen taken date: {pe.taken.isoformat()} ({delta:+d} days from event date)",
                  json.loads(scratch_fh.readline().decode("utf-8"))["text"]]
    for row in ev.notes:
        parts += ["", "<<< COLONOSCOPY REPORT >>>",
                  f"Report date: {_parse_dt(row['NoteDateTime']).date().isoformat()}",
                  row["ReportText"]]
    for i, row in enumerate(ev.fallback_notes, 1):
        parts += ["", f"<<< NEARBY NOTE {i} of {n_fb} -- NOT confirmed to be a procedure "
                      f"report; may be unrelated to this colonoscopy >>>",
                  f"Note date: {_parse_dt(row['NoteDateTime']).date().isoformat()}",
                  row["ReportText"]]
    body = "\n".join(parts)
    return body.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\\n")


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
    ap.add_argument("--window-days", type=int, default=10,
                    help="one window for all linking: clustering, anchor attachment, and the "
                         "lookahead of the nearby-note fallback")
    ap.add_argument("--max-notes", type=int, default=3,
                    help="cap on notes per event, applied separately to confirmed reports and "
                         "to nearby notes; the ones closest to the anchor are kept")
    args = ap.parse_args()

    outdir = Path(args.out_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    scratch = Path(args.scratch_dir or args.out_dir) / "path_text.jsonl"
    scratch.parent.mkdir(parents=True, exist_ok=True)

    path_index = _build_path_index(Path(args.path_csv), scratch)
    cpt_index = _read_cpt(Path(args.cpt_csv))

    whitelist = None
    if args.whitelist:
        with open(args.whitelist, encoding="utf-8") as f:
            whitelist = {ln.strip() for ln in f if ln.strip()}
        print(f"[colonoscopy_event] gate: whitelist of {len(whitelist):,} note IDs",
              file=sys.stderr)

    def is_report(row):
        """The model gate when a whitelist is supplied, the regex otherwise."""
        if whitelist is not None:
            return row["NoteID"] in whitelist
        return bool(GATE_PROC.search(row["ReportText"])
                    and GATE_STRUCTURE.search(row["ReportText"]))

    in_w = (outdir / "inputs_1.txt").open("w", encoding="utf-8")
    id_w = (outdir / "IDs_1.txt").open("w", encoding="utf-8")
    man_f = (outdir / "manifest.csv").open("w", encoding="utf-8", newline="")
    man = csv.writer(man_f)
    man.writerow(["event_id", "PatientICN", "event_date", "anchor_source", "emitted",
                  "n_colo_notes", "colo_note_ids", "n_nearby_notes", "nearby_note_ids",
                  "cpt_dates", "n_path", "path_sids", "path_tiu_sids", "path_offset_days",
                  "input_chars"])
    counts = defaultdict(int)

    def emit(icn, events, fh):
        for seq, ev in enumerate(events, 1):
            eid = f"{icn}|{ev.anchor.strftime('%Y%m%d')}|{seq}"
            # A CPT with no pathology and no note in the window has nothing to read: the input
            # would be a SOURCES header and a date, and the model could only answer nulls. Keep
            # the manifest row -- it is still a real event for denominators -- but do not spend
            # inference on it. Aggregation synthesizes those rows from emitted=0.
            has_text = bool(ev.paths or ev.notes or ev.fallback_notes)
            line = build_input(ev, fh) if has_text else ""
            if has_text:
                in_w.write(line + "\n")
                id_w.write(eid + "\n")
            anchor_source = "specimen" if ev.paths else "note" if ev.notes else "cpt"
            man.writerow([
                eid, icn, ev.anchor.isoformat(), anchor_source, int(has_text),
                len(ev.notes), ";".join(r["NoteID"] for r in ev.notes),
                len(ev.fallback_notes), ";".join(r["NoteID"] for r in ev.fallback_notes),
                ";".join(d.isoformat() for d in ev.cpt_dates),
                len(ev.paths), ";".join(pe.sid for _, pe in ev.paths),
                ";".join(pe.tiu_sid for _, pe in ev.paths),
                ";".join(str(d) for d, _ in ev.paths), len(line)])
            counts["events"] += 1
            counts["emitted"] += has_text
            counts["with_path"] += bool(ev.paths)
            counts["with_report"] += bool(ev.notes)
            counts["with_nearby_only"] += bool(ev.fallback_notes and not ev.notes)
            counts["with_cpt"] += bool(ev.cpt_dates)
            counts["chars"] += len(line)

    source = _iter_buckets(Path(args.buckets)) if args.buckets else _iter_single_csv(Path(args.notes))
    seen = set()
    with scratch.open("rb") as fh:
        for icn, rows in source:
            seen.add(icn)
            dated = [r for r in rows if _parse_dt(r["NoteDateTime"])]
            wl_notes = [r for r in dated if is_report(r)]
            paths, cpts = path_index.get(icn, []), cpt_index.get(icn, [])
            if not (wl_notes or paths or cpts):
                continue
            emit(icn, cluster_patient(dated, wl_notes, cpts, paths, args.window_days, args.max_notes), fh)

        # Patients whose pathology or CPT rows never met a note bucket still have real events.
        # Dropping them is exactly the path-without-CPT loss this pipeline exists to avoid.
        for icn in sorted((set(path_index) | set(cpt_index)) - seen):
            counts["patients_no_notes"] += 1
            emit(icn, cluster_patient([], [], cpt_index.get(icn, []), path_index.get(icn, []),
                                      args.window_days, args.max_notes), fh)

    for w in (in_w, id_w, man_f):
        w.close()
    n = max(counts["emitted"], 1)
    print(f"[colonoscopy_event] {counts['events']:,} events, {counts['emitted']:,} emitted "
          f"({counts['events'] - counts['emitted']:,} text-free, manifest only) | "
          f"path {counts['with_path']:,} | confirmed report {counts['with_report']:,} | "
          f"nearby-notes only {counts['with_nearby_only']:,} | cpt {counts['with_cpt']:,} | "
          f"mean {counts['chars'] // n:,} chars/emitted input | "
          f"{counts['patients_no_notes']:,} patients had no notes in the buckets -> {outdir}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
