#!/usr/bin/env python3
"""
extract_egd_event.py -- one model input per UPPER-ENDOSCOPY (EGD) EVENT.

The unit is the procedure, not the note and not the pathology report. An event is assembled
from up to three independent sources, any of which may be missing:

  * upper-GI pathology reports   (--path-csv: one row per SurgicalPathologySID)
  * an EGD procedure report      (note buckets, gated by Yes/No model -> [input with --whitelist])
  * EGD CPT codes                (--cpt-csv:  PatientICN, CPT_date)

Keying on pathology alone drops every clean exam with no biopsy, and those exams are the
denominators for surveillance interval and exposure time. Keying on the event keeps
CPT-without-path and path-without-CPT as ordinary rows -- and, because a whitelisted report can
seed its own event, an EGD documented only in a VA note with no billed CPT (an outside or
otherwise unbilled procedure) is kept too, rather than being out of scope by construction.

Assembly, in strict priority order -- steps 1-3 anchor the event (attachment within
--window-days), step 4 adds context:

  1. SpecimenTakenDate is the primary anchor. It records when tissue was taken, which is a
     fact about the procedure. Pathology dates are swept into clusters first, and those
     clusters ARE the events.
  2. CPT dates attach to the nearest pathology anchor in range, or seed their own events. ProcDate
     is the actual procedure/billing date, so it anchors an event better than a report's signing
     timestamp -- CPT is prioritized over reports.
  3. Whitelisted report notes attach last, to the nearest existing anchor (pathology or CPT), or
     seed their own events. NoteDateTime is EntryDateTime -- a SIGNING timestamp -- so it can lag
     the procedure and never overrides a specimen or CPT date. Loose reports (nothing within
     --window-days) cluster on the wider --window-days gap, not --merge-days, since several notes
     may discuss one external/unbilled EGD days apart.

  4. Clinical-note context, always labeled CLINICAL NOTE (never EGD REPORT) so the model knows
     it is reading nearby context, not a verified procedure report. Every event is filled to at
     most --max-notes notes TOTAL, the ones nearest the anchor within [anchor - --lookback-days,
     anchor + --window-days]. A gate-confirmed report COUNTS toward that budget, so a report event
     carries the report plus the nearest OTHER notes up to the cap; an event with no confirmed
     report spends the whole budget on context (the report may be there under a title the gate
     rejected, or the findings may live only in a clinic note). A report is never reused as its
     own context.

Clustering (turning a spray of dates into events) uses the tight --merge-days gap for pathology
and CPT dates, not the attachment window: repeat upper endoscopies within a couple of weeks are
ordinary -- serial dilations, a look-back after a bleed -- so a wide gap would fuse genuinely
separate billed EGDs into one event. Loose report notes cluster on the wider --window-days gap
instead, because a report is dated by when it was signed. Attachment uses the wide --window-days;
context notes reach --lookback-days before the anchor and --window-days after.

Pathology reports also sit in the note buckets, where their clinical-history line names an EGD,
so each would otherwise appear twice -- once as a CLINICAL NOTE and again as the PATHOLOGY REPORT
it is -- while crowding out real notes under --max-notes. Their TIU note IDs are collected while
indexing pathology and dropped from the note stream.

Nothing is truncated. A report's findings and impression are what the extraction needs and both
sit at the end, so a size cap here would silently cost accuracy; the ctx budget is set in
jobs.conf instead. Watch manifest.csv's input_chars to size it.

Documents are emitted as one chronological stream, each labeled EGD REPORT, CLINICAL NOTE, or
PATHOLOGY REPORT, ties going to the endoscopic document. The labels are what let the model
separate "the report is silent on Barrett's" from "there is no report" -- opposite facts
downstream that would otherwise both arrive as "unknown".

Newlines are escaped to a literal backslash-n: data-extraction.cpp splits --file on '\n' (one
record per line) and calls convertEscapedNewlines() on each record itself.

    ./extract_egd_event.py --buckets /data/note_buckets \
        --path-csv  /data/path/egd_pathReports.csv.gz \
        --cpt-csv   /data/path/egd_CPT.csv.gz \
        --whitelist /data/models/inputs/egd_details_extraction/whitelist.txt \
        --out-dir   /data/models/inputs/egd_details_extraction
"""
import argparse
import csv
import json
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, timedelta
from pathlib import Path


# snippet_lib ships with the preprocessing scripts. Import it from there rather than duplicating
# its bucket reader and date parser, both of which every task depends on behaving identically.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "preprocessing"))
from snippet_lib import _iter_buckets, _iter_single_csv, _open_maybe_gzip, _parse_dt  # noqa: E402


@dataclass
class Event:
    anchor: date
    anchor_source: str = ""                             # what set the anchor: specimen|cpt|note
    notes: list = field(default_factory=list)           # gate-confirmed EGD reports
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
    a note onto a CPT onto a specimen across a span far wider than the gap."""
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
    """Stream the pathology CSV once, writing PathReportText to a scratch JSONL and keeping only
    a light index in RAM (~80 bytes/report). The bucket loop then seeks by byte offset, so the
    full corpus of nvarchar(max) report text is never resident.

    Returns (index, path_note_ids). path_note_ids holds the TIU note IDs of the pathology
    reports themselves, to drop from the note stream (see the module docstring)."""
    index = defaultdict(list)
    path_note_ids = set()
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
            tiu = (row.get(c_tiu) or "") if c_tiu else ""
            index[row[c_icn]].append(PathEntry(
                sid=row[c_sid], taken=taken.date(), offset=offset, tiu_sid=tiu))
            for sid in tiu.split(","):        # one accession can carry several
                if sid.strip():
                    path_note_ids.add(sid.strip())
            offset += len(blob)
            n_rows += 1
    print(f"[egd_event] indexed {n_rows:,} pathology reports for {len(index):,} patients "
          f"({len(path_note_ids):,} pathology note IDs to exclude from the note list)",
          file=sys.stderr)
    return index, path_note_ids


def _read_cpt(cpt_csv: Path):
    """PatientICN -> sorted list of distinct EGD CPT dates."""
    by_pt = defaultdict(set)
    with _open_maybe_gzip(cpt_csv) as f:
        reader = csv.DictReader(f)
        cols = {c.lower(): c for c in (reader.fieldnames or [])}
        c_icn = cols.get("patienticn") or cols.get("patientid")
        c_date = cols.get("cpt_date") or cols.get("egd_cpt") or cols.get("procdate")
        if not (c_icn and c_date):
            raise SystemExit(f"{cpt_csv}: need PatientICN and CPT_date/EGD_CPT; "
                             f"got {reader.fieldnames}")
        for row in reader:
            dt = _parse_dt(row[c_date])
            if dt:
                by_pt[row[c_icn]].add(dt.date())
    print(f"[egd_event] read CPT dates for {len(by_pt):,} patients", file=sys.stderr)
    return {k: sorted(v) for k, v in by_pt.items()}


def cluster_patient(all_notes, wl_notes, cpt_dates, path_entries,
                    window, merge_days, max_notes, lookback_days):
    """Return the patient's events, ordered by anchor date. This is the whole of the linkage
    logic and the only place it lives; see the module docstring for the priority order.

    Clustering into events uses merge_days for pathology/CPT (tight); loose report notes cluster
    with the wider window gap; attachment across kinds uses window; context notes are the nearest
    within [anchor - lookback_days, anchor + window]."""
    events = []

    # 1. Pathology first: SpecimenTakenDate is the most reliable date we have.
    for cluster in _sweep(sorted(((pe.taken, pe) for pe in path_entries), key=lambda x: x[0]),
                          merge_days):
        ev = Event(anchor=cluster[0][0], anchor_source="specimen")
        ev.paths = [(int((pe.taken - ev.anchor).days), pe) for _, pe in cluster]
        events.append(ev)

    # 2. CPT dates next: ProcDate is the actual procedure/billing date, so it anchors an event
    #    better than a report's signing timestamp -- CPT takes priority over reports. Each attaches
    #    to the nearest pathology anchor in range, or seeds its own event.
    loose = []
    for d in cpt_dates:
        ev = _nearest(events, d, window)
        if ev is None:
            loose.append((d, d))
        else:
            ev.cpt_dates.append(d)
    for cluster in _sweep(sorted(loose, key=lambda x: x[0]), merge_days):
        ev = Event(anchor=cluster[0][0], anchor_source="cpt")
        ev.cpt_dates = [d for _, d in cluster]
        events.append(ev)

    # 3. Gate-confirmed reports last. They attach to the nearest existing anchor (pathology or
    #    CPT), or seed their own events. NoteDateTime is EntryDateTime -- a SIGNING timestamp -- so
    #    it can lag the procedure and never overrides a specimen or CPT date.
    loose = []
    for r in wl_notes:
        d = _parse_dt(r["NoteDateTime"]).date()
        ev = _nearest(events, d, window)
        if ev is None:
            loose.append((d, r))
        else:
            ev.notes.append(r)
    # Loose reports cluster on the wider --window-days gap, not --merge-days: a report is dated by
    # its SIGNING date, so several notes may discuss one external/unbilled EGD days apart.
    for cluster in _sweep(sorted(loose, key=lambda x: x[0]), window):
        ev = Event(anchor=cluster[0][0], anchor_source="note")
        ev.notes = [r for _, r in cluster]
        events.append(ev)

    # 4. Clinical-note context (see the module docstring). Every event is filled to at most
    #    max_notes notes total, the ones nearest the anchor within [anchor - lookback_days,
    #    anchor + window]. A gate-confirmed report COUNTS toward that budget, so a report event
    #    carries the report plus the nearest OTHER notes up to the cap. A report is never reused as
    #    its own context (report_ids covers every event's reports), and pathology notes are already
    #    out of the note stream.
    report_ids = {r["NoteID"] for r in wl_notes}
    lo_off, hi_off = timedelta(days=lookback_days), timedelta(days=window)
    for ev in events:
        ev.notes = _closest(ev.notes, ev.anchor, max_notes)   # reports capped first: they count toward the budget
        budget = max_notes - len(ev.notes)
        if budget <= 0:
            continue
        lo, hi = ev.anchor - lo_off, ev.anchor + hi_off
        cand = []
        for r in all_notes:
            if r["NoteID"] in report_ids:
                continue
            d = _parse_dt(r["NoteDateTime"])
            if d and lo <= d.date() <= hi:
                cand.append(r)
        ev.fallback_notes = _closest(cand, ev.anchor, budget)

    events.sort(key=lambda e: e.anchor)
    return events


def build_input(ev, scratch_fh):
    """Render one event as the model input, each document labeled with what it is and dated.

    When a confirmed report exists, the report and its surrounding CLINICAL NOTE context (kind 0)
    are shown in date order and ALL precede the pathology (kind 1): the report is the procedure and
    the pathology is downstream of it, and matching jars to lesions reads naturally in that
    direction. Date order within kind 0 places earlier context (e.g. the indication) ahead of the
    report and later context (e.g. the follow-up) after it -- the report itself is dated by when it
    was SIGNED (often a day or more later) while a specimen is dated by when it was taken, which is
    the procedure date itself, so pathology going last keeps the report ahead of the tissue it
    explains.

    With no confirmed report, documents stay in date order, same-day ties going to the clinical
    note."""
    docs = []
    for row in ev.notes:
        docs.append((_parse_dt(row["NoteDateTime"]).date(), 0, "EGD REPORT", row, None))
    for row in ev.fallback_notes:
        docs.append((_parse_dt(row["NoteDateTime"]).date(), 0, "CLINICAL NOTE", row, None))
    for _, pe in ev.paths:
        docs.append((pe.taken, 1, "PATHOLOGY REPORT", None, pe))
    # kind-major when a report anchors the reading, date-major otherwise.
    docs.sort(key=(lambda d: (d[1], d[0])) if ev.notes else (lambda d: (d[0], d[1])))

    parts = [f"Event date: {ev.anchor.isoformat()}"]
    for d, _, label, row, pe in docs:
        if pe is not None:
            scratch_fh.seek(pe.offset)
            text = json.loads(scratch_fh.readline().decode("utf-8"))["text"]
        else:
            text = row["ReportText"]
        parts += ["", f"<<< {label} -- {d.isoformat()} >>>", text]
    body = "\n".join(parts)
    return body.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\\n")


def main():
    ap = argparse.ArgumentParser(description="Build one input per EGD event.")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--buckets", help="dir of bucket_*.csv.gz note buckets")
    src.add_argument("--notes", help="single notes CSV")
    ap.add_argument("--path-csv", required=True, help="one row per SurgicalPathologySID")
    ap.add_argument("--cpt-csv", required=True, help="PatientICN, CPT_date")
    ap.add_argument("--out-dir", default="egd_event_inputs")
    ap.add_argument("--scratch-dir", default=None, help="defaults to --out-dir")
    ap.add_argument("--whitelist", required=True,
                    help="file of note IDs the egd_report_yn gate answered Yes for. Required: the "
                         "gate is the only thing that decides which notes are procedure reports "
                         "(no regex fallback).")
    ap.add_argument("--window-days", type=int, default=15,
                    help="max |document date - anchor| for a report, note, or specimen to "
                         "attach, and the forward reach for context notes")
    ap.add_argument("--merge-days", type=int, default=2,
                    help="gap above which two same-kind PATHOLOGY or CPT dates start separate "
                         "events; kept tight (a few days) so repeat EGDs -- serial dilations, a "
                         "bleed look-back -- are not fused, while one procedure's multi-day dates "
                         "still cluster. Loose report notes instead cluster on --window-days")
    ap.add_argument("--max-notes", type=int, default=5,
                    help="cap on notes per event TOTAL, gate-confirmed report(s) included; the "
                         "remaining slots are filled with the notes nearest the anchor")
    ap.add_argument("--lookback-days", type=int, default=5,
                    help="how many days BEFORE the anchor a context note may fall; the forward "
                         "reach is --window-days. Applies whether or not a report was confirmed")
    args = ap.parse_args()

    outdir = Path(args.out_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    scratch = Path(args.scratch_dir or args.out_dir) / "path_text.jsonl"
    scratch.parent.mkdir(parents=True, exist_ok=True)

    path_index, path_note_ids = _build_path_index(Path(args.path_csv), scratch)
    cpt_index = _read_cpt(Path(args.cpt_csv))

    with open(args.whitelist, encoding="utf-8") as f:
        whitelist = {ln.strip() for ln in f if ln.strip()}
    print(f"[egd_event] gate: whitelist of {len(whitelist):,} note IDs", file=sys.stderr)

    def is_report(row):
        """A note is a procedure report iff the egd_report_yn gate answered Yes for it."""
        return row["NoteID"] in whitelist

    in_w = (outdir / "inputs_1.txt").open("w", encoding="utf-8")
    id_w = (outdir / "IDs_1.txt").open("w", encoding="utf-8")
    man_f = (outdir / "manifest.csv").open("w", encoding="utf-8", newline="")
    man = csv.writer(man_f)
    man.writerow(["event_id", "PatientICN", "event_date", "anchor_source", "emitted",
                  "n_egd_notes", "egd_note_ids", "n_nearby_notes", "nearby_note_ids",
                  "cpt_dates", "n_path", "path_sids", "path_tiu_sids", "path_offset_days",
                  "input_chars"])
    counts = defaultdict(int)

    def emit(icn, events, fh):
        for seq, ev in enumerate(events, 1):
            eid = f"{icn}_{ev.anchor.strftime('%Y%m%d')}_{seq}"
            # A CPT with no pathology and no note in the window has nothing to read: the input
            # would be a date line and the model could only answer nulls. Keep the manifest row
            # -- it is still a real EGD for denominators -- but do not spend inference on it.
            has_text = bool(ev.paths or ev.notes or ev.fallback_notes)
            line = build_input(ev, fh) if has_text else ""
            if has_text:
                in_w.write(line + "\n")
                id_w.write(eid + "\n")
            anchor_source = ev.anchor_source
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
            dated = []
            for r in rows:
                if r["NoteID"] in path_note_ids:
                    counts["path_notes_dropped"] += 1
                    continue
                if _parse_dt(r["NoteDateTime"]):
                    dated.append(r)
            wl_notes = [r for r in dated if is_report(r)]
            paths, cpts = path_index.get(icn, []), cpt_index.get(icn, [])
            if not (wl_notes or paths or cpts):
                continue
            emit(icn, cluster_patient(dated, wl_notes, cpts, paths, args.window_days,
                                      args.merge_days, args.max_notes, args.lookback_days), fh)

        # Patients whose pathology or CPT rows never met a note bucket still have real events.
        # Dropping them is exactly the path-without-CPT loss this pipeline exists to avoid.
        for icn in sorted((set(path_index) | set(cpt_index)) - seen):
            counts["patients_no_notes"] += 1
            emit(icn, cluster_patient([], [], cpt_index.get(icn, []), path_index.get(icn, []),
                                      args.window_days, args.merge_days, args.max_notes,
                                      args.lookback_days), fh)

    for w in (in_w, id_w, man_f):
        w.close()
    n = max(counts["emitted"], 1)
    print(f"[egd_event] {counts['events']:,} events, {counts['emitted']:,} emitted "
          f"({counts['events'] - counts['emitted']:,} text-free, manifest only) | "
          f"path {counts['with_path']:,} | confirmed report {counts['with_report']:,} | "
          f"nearby-notes only {counts['with_nearby_only']:,} | cpt {counts['with_cpt']:,} | "
          f"{counts['path_notes_dropped']:,} pathology notes dropped | "
          f"mean {counts['chars'] // n:,} chars/emitted input | "
          f"{counts['patients_no_notes']:,} patients had no notes in the buckets -> {outdir}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
