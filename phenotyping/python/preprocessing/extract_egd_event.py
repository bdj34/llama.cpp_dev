#!/usr/bin/env python3
"""
extract_egd_event.py -- one model input per UPPER-ENDOSCOPY (EGD) EVENT.

CPT-anchored, unlike the colonoscopy pipeline. The EGD pathology extract is already built
with a CROSS APPLY against the CPT table, so every pathology report in it has a CPT within
the pull window and pathology-without-CPT cannot occur. That makes the CPT date the spine,
and it means an EGD that was never billed is out of scope by construction.

There is no small-model gate here. Notes reach the input on a regex prefilter alone, so they
are labeled CLINICAL NOTE, never "report" -- one of them is usually the EGD report, but the
others may be clinic, nursing, or ward notes, and nothing has verified which is which. Only
the --max-notes nearest the CPT date are kept, since a hospital stay can put dozens of
matching notes inside the window and the nearest few are the ones describing the procedure.

Per patient:
  1. CPT dates are swept into events (a new event when the gap exceeds --merge-days), so two
     codes billed a day apart for one procedure do not become two EGDs.
  2. Every pathology report within --window-days attaches to its NEAREST event. Nearest-wins
     rather than all-within-window, so one specimen never appears under two events and
     lesions are not double counted.
  3. Prefilter-matching notes within --window-days attach, --max-notes nearest kept. A note
     CAN serve two events when they are close together; it is context, not a specimen.

Documents are emitted as one chronological stream, each labeled and dated, same-day ties
going to the note. Nothing is truncated. Events with no pathology and no note are recorded in
the manifest but not emitted -- the model could only answer nulls for them.

Newlines are escaped to a literal backslash-n: data-extraction.cpp splits --file on '\n'
(one record per line) and calls convertEscapedNewlines() on each record itself.

    ./extract_egd_event.py --buckets /data/models/be_eac/note_buckets \
        --path-csv /data/models/be_eac/egd_pathReports.csv.gz \
        --cpt-csv  /data/models/be_eac/egd_CPT.csv.gz \
        --out-dir  /data/models/inputs/egd_details_extraction
"""
import argparse
import csv
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, time
from pathlib import Path

from snippet_lib import _iter_buckets, _iter_single_csv, _open_maybe_gzip, _parse_dt

# Names an upper endoscopy. Recall-favouring and structure-free: with no model gate, this is
# the only filter, and the extraction itself judges whether a note is the procedure report.
PREFILTER = re.compile(
    r"(?i)(?:\besophagogastroduodenoscop\w*|\bes?ophagoscop\w*|\bgastroscop\w*|"
    r"\bpanendoscop\w*|\begd\b|\bupper\s+(?:gi\s+)?endoscop\w*)"
)


@dataclass
class Event:
    anchor: date
    cpt_dates: list = field(default_factory=list)
    notes: list = field(default_factory=list)   # bucket rows, prefilter-matched
    paths: list = field(default_factory=list)   # (offset_days, PathEntry)


@dataclass
class PathEntry:
    sid: str
    taken: date
    offset: int          # byte offset into the scratch JSONL
    tiu_sid: str


def _sweep(dated, gap_days):
    """Group a sorted (date, payload) list into clusters, breaking whenever the gap to the
    previous date exceeds gap_days."""
    cluster, prev = [], None
    for d, payload in dated:
        if prev is not None and (d - prev).days > gap_days:
            yield cluster
            cluster = []
        cluster.append((d, payload))
        prev = d
    if cluster:
        yield cluster


def _build_path_index(path_csv: Path, scratch: Path):
    """Stream the pathology CSV once, writing PathReportText to a scratch JSONL and keeping
    only a light index in RAM (~80 bytes/report). The event loop then seeks by byte offset, so
    2.5M nvarchar(max) reports are never resident.

    Returns (index, path_note_ids). path_note_ids holds the TIU note IDs of the pathology
    reports themselves: those notes also sit in the buckets and say "EGD" in their clinical
    history, so the prefilter matches them and they would be shown twice -- once as a CLINICAL
    NOTE and again as the PATHOLOGY REPORT they are -- while crowding out real notes under the
    --max-notes cap."""
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
            blob = json.dumps({"text": text}).encode("utf-8") + b"\n"
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


def cluster_patient(cpt_dates, notes, path_entries, window, merge_days, max_notes):
    """Return the patient's events, ordered by anchor date. The CPT dates ARE the spine; notes
    and pathology only attach to them."""
    events = []
    for cluster in _sweep([(d, d) for d in cpt_dates], merge_days):
        ev = Event(anchor=cluster[0][0])
        ev.cpt_dates = [d for _, d in cluster]
        events.append(ev)
    if not events:
        return []

    for pe in path_entries:
        near = [(abs((pe.taken - e.anchor).days), pe.taken < e.anchor, e) for e in events]
        near = [c for c in near if c[0] <= window]
        if not near:
            continue
        # Nearest anchor wins; a tie goes to the event the specimen FOLLOWS, since tissue is
        # taken at or after the procedure, never before it.
        _, _, ev = min(near, key=lambda c: (c[0], c[1]))
        ev.paths.append((int((pe.taken - ev.anchor).days), pe))

    dated_notes = [(_parse_dt(r["NoteDateTime"]), r) for r in notes]
    for ev in events:
        # Every note written on the procedure day is kept, cap or not: one of them is the EGD
        # report, and which one is not knowable here without reading them. The cap governs only
        # the surrounding days, and same-day notes count against it, so an event with more
        # same-day notes than the cap simply keeps them all.
        same_day, other = [], []
        for dt, r in dated_notes:
            gap = abs((dt.date() - ev.anchor).days)
            if gap == 0:
                same_day.append((dt, r))
            elif gap <= window:
                other.append((gap, dt.date() < ev.anchor, dt, r))
        # Sort on an explicit key -- the row dict is not orderable and same-day notes tie on
        # both distance and date. Equidistant notes go to the one at or AFTER the CPT date: a
        # note two days before is pre-procedure, two days after is usually the report.
        other.sort(key=lambda c: (c[0], c[1], c[2]))
        room = max(max_notes - len(same_day), 0)
        chosen = same_day + [(dt, r) for _, _, dt, r in other[:room]]
        ev.notes = [r for _, r in sorted(chosen, key=lambda c: c[0])]

    return events


def build_input(ev, scratch_fh):
    """One event as the model input: every document in date order, each labeled and dated.
    Same-day ties put the note first -- pathology is downstream of the procedure and reads
    better after the endoscopic description."""
    # Sort on (date, kind, time): notes carry a full EntryDateTime and pathology only a
    # specimen date, so the day is the shared key. Same-day ties put the notes first, in
    # timestamp order -- pathology is downstream of the procedure and reads better after it.
    docs = []
    for r in ev.notes:
        dt = _parse_dt(r["NoteDateTime"])
        docs.append((dt.date(), 0, dt.time(), "CLINICAL NOTE",
                     dt.strftime("%Y-%m-%d %H:%M"), r, None))
    for _, pe in ev.paths:
        docs.append((pe.taken, 1, time.min, "PATHOLOGY REPORT",
                     pe.taken.isoformat(), None, pe))
    docs.sort(key=lambda d: (d[0], d[1], d[2]))

    parts = [f"Event date: {ev.anchor.isoformat()}"]
    for *_, label, stamp, row, pe in docs:
        if pe is not None:
            scratch_fh.seek(pe.offset)
            text = json.loads(scratch_fh.readline().decode("utf-8"))["text"]
        else:
            text = row["ReportText"]
        parts += ["", f"<<< {label} -- {stamp} >>>", text]
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
    ap.add_argument("--window-days", type=int, default=15,
                    help="max |document date - CPT date| for a note or specimen to attach")
    ap.add_argument("--merge-days", type=int, default=1,
                    help="gap above which two CPT dates start separate events")
    ap.add_argument("--max-notes", type=int, default=5,
                    help="notes per event, the ones nearest the CPT date")
    args = ap.parse_args()

    outdir = Path(args.out_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    scratch = Path(args.scratch_dir or args.out_dir) / "path_text.jsonl"
    scratch.parent.mkdir(parents=True, exist_ok=True)

    path_index, path_note_ids = _build_path_index(Path(args.path_csv), scratch)
    cpt_index = _read_cpt(Path(args.cpt_csv))

    in_w = (outdir / "inputs_1.txt").open("w", encoding="utf-8")
    id_w = (outdir / "IDs_1.txt").open("w", encoding="utf-8")
    man_f = (outdir / "manifest.csv").open("w", encoding="utf-8", newline="")
    man = csv.writer(man_f)
    man.writerow(["event_id", "PatientICN", "event_date", "emitted", "cpt_dates",
                  "n_notes", "note_ids", "n_path", "path_sids", "path_tiu_sids",
                  "path_offset_days", "input_chars"])
    counts = defaultdict(int)

    def emit(icn, events, fh):
        for seq, ev in enumerate(events, 1):
            eid = f"{icn}_{ev.anchor.strftime('%Y%m%d')}_{seq}"
            # A CPT with no pathology and no matching note has nothing to read: the input would
            # be one date line and the model could only answer nulls. Keep the manifest row --
            # it is still a real EGD for denominators -- but do not spend inference on it.
            has_text = bool(ev.paths or ev.notes)
            line = build_input(ev, fh) if has_text else ""
            if has_text:
                in_w.write(line + "\n")
                id_w.write(eid + "\n")
            man.writerow([
                eid, icn, ev.anchor.isoformat(), int(has_text),
                ";".join(d.isoformat() for d in ev.cpt_dates),
                len(ev.notes), ";".join(r["NoteID"] for r in ev.notes),
                len(ev.paths), ";".join(pe.sid for _, pe in ev.paths),
                ";".join(pe.tiu_sid for _, pe in ev.paths),
                ";".join(str(d) for d, _ in ev.paths), len(line)])
            counts["events"] += 1
            counts["emitted"] += has_text
            counts["with_path"] += bool(ev.paths)
            counts["with_note"] += bool(ev.notes)
            counts["chars"] += len(line)

    source = _iter_buckets(Path(args.buckets)) if args.buckets else _iter_single_csv(Path(args.notes))
    seen = set()
    with scratch.open("rb") as fh:
        for icn, rows in source:
            seen.add(icn)
            cpts = cpt_index.get(icn)
            if not cpts:
                continue                      # no billed EGD: nothing to anchor an event on
            notes = []
            for r in rows:
                if r["NoteID"] in path_note_ids:
                    counts["path_notes_dropped"] += 1
                    continue
                if _parse_dt(r["NoteDateTime"]) and PREFILTER.search(r["ReportText"]):
                    notes.append(r)
            counts["prefiltered_notes"] += len(notes)
            emit(icn, cluster_patient(cpts, notes, path_index.get(icn, []),
                                      args.window_days, args.merge_days, args.max_notes), fh)

        # Patients with a CPT whose notes never met a bucket still have real EGDs, and may have
        # pathology. Skipping them would drop those events from the denominator.
        for icn in sorted(set(cpt_index) - seen):
            counts["patients_no_notes"] += 1
            emit(icn, cluster_patient(cpt_index[icn], [], path_index.get(icn, []),
                                      args.window_days, args.merge_days, args.max_notes), fh)

    for w in (in_w, id_w, man_f):
        w.close()
    n = max(counts["emitted"], 1)
    print(f"[egd_event] {counts['events']:,} events, {counts['emitted']:,} emitted "
          f"({counts['events'] - counts['emitted']:,} text-free, manifest only) | "
          f"path {counts['with_path']:,} | notes {counts['with_note']:,} | "
          f"{counts['prefiltered_notes']:,} notes matched the prefilter "
          f"({counts['path_notes_dropped']:,} pathology notes dropped) | "
          f"mean {counts['chars'] // n:,} chars/emitted input | "
          f"{counts['patients_no_notes']:,} patients had no notes in the buckets -> {outdir}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
