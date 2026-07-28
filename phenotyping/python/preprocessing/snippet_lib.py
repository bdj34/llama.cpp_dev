"""
snippet_lib.py -- shared engine for the per-task snippet extractors.

Each task script (extract_ibd.py, extract_crc.py, ...) defines a TaskConfig and
calls run(cfg). The engine reads the v2 patient-hash buckets (bucket_*.csv.gz from
reproduce_results/v2/combined_step1_pull_notes.R) ONE bucket at a time -- because R
hashed every note by PatientID, a bucket holds ALL of a patient's notes, so we can
cover a patient's whole history without loading the corpus. A single --notes CSV is
also supported.

Pipeline per patient:

  1. Cut character-window snippets around each concept-regex hit (overlapping windows
     merged; over-long merged blocks truncated head+tail so one block can't eat the
     budget).
  2. Deduplicate. Exact dedup misses the copy-forward blocks that dominate CPRS notes,
     so the default "normalized" mode collapses snippets that differ only in SHORT
     numbers (lab values, vitals, doses) while KEEPING 4-digit years -- redundant
     repeats disappear but distinct diagnosis years survive.
  3. Tag each snippet with its note date and a task "priority" flag (the decisive
     evidence, e.g. an IBD-diagnosis-year statement). An ignore_regex drops off-target
     context (e.g. CRC screening), but a priority snippet overrides ignore.
  4. Emit N distinct inputs per patient (default 3). Each input shares the high-value
     anchors (most-recent + most-distant + priority) so no model misses the decisive
     evidence; the rest of the budget is filled COMPLEMENTARILY -- within each slice of
     the timeline, each replicate is handed a different snippet -- so feeding input_k to
     model k yields a real consensus whose union spans far more history than any single
     read. When a patient fits under budget, the inputs are identical (nothing to drop).

Budgets are larger than the old line-window scripts on purpose: gemma-4 / Qwen-3.6 have
ample context, so we show the model more of the patient history.
"""

import argparse
import csv
import gzip
import hashlib
import json
import random
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field, fields
from datetime import datetime
from pathlib import Path
from typing import Optional

csv.field_size_limit(min(sys.maxsize, 2**31 - 1))

# Tolerant date matcher: pulls the leading Y-M-D (with optional time) out of whatever the note
# datetime looks like. Handles the ISO 8601 form data.table::fwrite writes ("2020-05-01T09:00:00Z"),
# the space form ("2020-05-01 09:00:00"), date-only, and "/" separators -- ignoring any trailing
# fractional seconds / "Z" / timezone offset. This is the format that dropped every patient when
# it was an enumerated strptime list that did not include the "T...Z" variant.
_DT_RE = re.compile(r"\s*(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?")
_WS = re.compile(r"\s+")
# For dedup only: collapse 1-3 digit numbers (lab values, vitals, doses that vary between
# copy-forwards), but NEVER a number touching a date separator -- so "3/2016" and "4/2016"
# stay distinct instead of both becoming "#/2016". 4-digit years are never matched here.
_SHORTNUM = re.compile(r"(?<![\d/\-])\d{1,3}(?![\d/\-])")


# ---------------------------------------------------------------------------
# Progress output. Two kinds of line share the terminal, so route both through
# these helpers to avoid one shorter line leaving the tail of a longer one behind:
#   _progress -> transient, overwritten in place (a counter that keeps updating)
#   _logline  -> committed, stays on its own line (a per-bucket / final summary)
# On a TTY we use CR + clear-to-end-of-line (\033[K) so a short line fully erases a
# long one; when stderr is redirected to a file we just print plain lines (no CR
# soup), so `... 2> run.log` is clean and readable.
# ---------------------------------------------------------------------------
_TTY = sys.stderr.isatty()


def _progress(msg: str):
    sys.stderr.write(("\r" + msg + "\033[K") if _TTY else (msg + "\n"))
    sys.stderr.flush()


def _logline(msg: str):
    sys.stderr.write(("\r\033[K" + msg + "\n") if _TTY else (msg + "\n"))
    sys.stderr.flush()


@dataclass
class TaskConfig:
    name: str
    concept_regex: str                  # membership + snippet anchors (case-insensitive)
    question: Optional[str] = None       # appended once at the end of each input
    date_strftime: str = "%Y-%m-%d"      # per-snippet note-date label (full date aids
    date_label: str = "YYYY-MM-DD"       # relative-date reasoning by the model)
    ignore_regex: Optional[str] = None   # snippet matching this is dropped UNLESS priority
    ignore_scope: str = "snippet"        # "snippet" = any ignore hit drops it; "match" = drop
    ignore_radius: int = 60              # only if EVERY concept match sits within radius chars
    priority_regex: Optional[str] = None # of an ignore hit (no clean on-target mention remains)
    snip_chars: int = 350                # characters kept on each side of a hit
    max_snip_len: int = 1600             # truncate over-long merged blocks (head+tail)
    max_snips_per_note: int = 12
    snippet_budget: int = 45             # max snippets per input (per replicate)
    char_budget: int = 70000             # hard cap on snippet chars per input
    n_recent: int = 5                    # newest snippets, kept in every replicate
    n_distant: int = 12                  # oldest snippets, kept in every replicate
    priority_cap: int = 22               # at most this many priority anchors
    dedup: str = "normalized"            # "normalized" (near-dup) | "exact"
    header: bool = True                  # prepend a [Timeline: ...] orientation line
    mode: str = "consensus"             # "consensus" | "chunk"
    chunk_size: int = 25                 # snippets per input in "chunk" mode

    _concept: re.Pattern = field(default=None, repr=False)
    _ignore: re.Pattern = field(default=None, repr=False)
    _priority: re.Pattern = field(default=None, repr=False)

    def compile(self):
        """Compile the task's regex strings once into the private _concept/_ignore/_priority
        patterns the engine uses (case-insensitive; DOTALL so `.` spans newlines, which the
        lookahead-based priority patterns rely on). Returns self so callers can chain
        `TaskConfig(...).compile()`."""
        flags = re.IGNORECASE | re.DOTALL
        self._concept = re.compile(self.concept_regex, flags)
        self._ignore = re.compile(self.ignore_regex, flags) if self.ignore_regex else None
        self._priority = re.compile(self.priority_regex, flags) if self.priority_regex else None
        return self


# --------------------------------------------------------------------------
# Note reading.
# --------------------------------------------------------------------------
def _open_maybe_gzip(path: Path):
    """Open a notes file for text reading, transparently decompressing `.gz` buckets. Plain
    CSVs are opened utf-8-sig so a leading BOM from Excel/R exports is stripped."""
    if str(path).endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", newline="")
    return open(path, "r", encoding="utf-8-sig", newline="")


def _read_csv_rows(path: Path):
    """Yield one normalized dict per CSV row: {PatientID, NoteID, NoteDateTime, ReportText}.
    Columns are matched case-insensitively BY NAME (a header is required). Each key accepts an
    alias so both the local exports and VA CDW pulls work: patient = PatientID or PatientICN,
    note = NoteID or TIUDocumentSID, date = NoteDateTime (v2 buckets) or EntryDateTime (older
    exports). Raises if a required column is missing, so a malformed file fails loudly rather
    than yielding silent garbage."""
    with _open_maybe_gzip(path) as f:
        reader = csv.DictReader(f)
        cols = {c.lower(): c for c in (reader.fieldnames or [])}
        pid_c = cols.get("patientid") or cols.get("patienticn")
        note_c = cols.get("noteid") or cols.get("tiudocumentsid")
        date_c = cols.get("notedatetime") or cols.get("entrydatetime")
        text_c = cols.get("reporttext")
        if not (pid_c and text_c and date_c):
            raise SystemExit(
                f"{path}: need (PatientID|PatientICN), (NoteID|TIUDocumentSID), "
                f"(Note|Entry)DateTime, ReportText; got {reader.fieldnames}"
            )
        for row in reader:
            yield {
                "PatientID": row[pid_c],
                "NoteID": row.get(note_c, "") if note_c else "",
                "NoteDateTime": row[date_c],
                "ReportText": row[text_c],
            }


def _iter_buckets(bucket_dir: Path):
    """Stream (patient_id, [rows]) one bucket at a time -- the memory-safe primary path.

    A "bucket" is every shard sharing a `bucket_NN__*.csv.gz` prefix; because R hashed notes
    by PatientID, a bucket holds ALL notes for its patients. We load one bucket into RAM, group
    its rows by patient, drop repeated NoteIDs (a note can appear in >1 shard if a pull window
    was re-run), and yield complete patients -- never holding the whole corpus at once. Buckets
    are visited in sorted order so runs are reproducible."""
    shards = defaultdict(list)
    for p in bucket_dir.glob("bucket_*.csv.gz"):
        shards[p.name.split("__")[0]].append(p)
    if not shards:
        raise SystemExit(f"no bucket_*.csv.gz found in {bucket_dir}")
    for bucket, paths in sorted(shards.items()):
        by_pt, seen = defaultdict(list), set()
        nrows = 0
        for p in sorted(paths):
            for row in _read_csv_rows(p):
                if row["NoteID"]:
                    if row["NoteID"] in seen:
                        continue
                    seen.add(row["NoteID"])
                by_pt[row["PatientID"]].append(row)
                # In-place progress: a counter + a periodic \r write, so it costs one modulo
                # per row and nothing else (no extra passes over the data).
                nrows += 1
                if nrows % 200000 == 0:
                    _progress(f"  [{bucket}] reading... {nrows:,} rows")
        _logline(f"  [{bucket}] read {nrows:,} rows, {len(by_pt):,} patients")
        for pid, rows in by_pt.items():
            yield pid, rows


def _iter_single_csv(path: Path):
    """Group a single notes CSV by PatientID and yield (patient_id, [rows]). Convenience path
    for ad-hoc runs (--notes); unlike the bucket path, the whole file is read into memory."""
    by_pt = defaultdict(list)
    for row in _read_csv_rows(path):
        by_pt[row["PatientID"]].append(row)
    for pid, rows in by_pt.items():
        yield pid, rows


def _parse_dt(value: str) -> Optional[datetime]:
    """Parse a note timestamp leniently (see _DT_RE): accepts ISO 8601 with T/Z/offset, the
    space-separated form, date-only, and "/" separators. Returns None for blank/NULL/unparseable
    values -- those notes are skipped downstream, since every snippet needs a date label and a
    chronological sort key. (A too-strict version here silently drops every note -> every patient.)"""
    value = (value or "").strip()
    if not value or value.upper() == "NULL":
        return None
    m = _DT_RE.match(value)
    if not m:
        return None
    y, mo, d, hh, mi, ss = m.groups()
    try:
        return datetime(int(y), int(mo), int(d), int(hh or 0), int(mi or 0), int(ss or 0))
    except ValueError:
        return None


# --------------------------------------------------------------------------
# Snippet cutting + dedup.
# --------------------------------------------------------------------------
# A blank-line / section break: 3+ line breaks in a row (blank lines separating
# note sections). Horizontal whitespace between the newlines is tolerated.
_GAP = re.compile(r"(?:[ \t]*\n){3,}")

# Safety valve: stop collecting hits from a single note past this many. Set FAR above any
# realistic note so priority-snippet selection sees the WHOLE note; it only guards against a
# degenerate note (e.g. a copy-paste error with thousands of matches) blowing up cost.
_MAX_HITS_PER_NOTE = 2000


def _note_seed(text: str) -> int:
    """Deterministic seed for per-note snippet sampling, derived from the note text so the
    same note always samples the same snippets across runs (reproducible)."""
    return int(hashlib.md5(text.encode("utf-8")).hexdigest(), 16) % (2**31)


def _snap_left(text: str, s: int, core: int) -> int:
    """Choose the left edge of a snippet within the margin [s, core), where `core` is
    the start of the matched content (never trimmed past). If a section break falls in
    the margin, start just after the LAST one (drop the unrelated section before it);
    otherwise snap forward off any partial leading word so we never begin mid-word."""
    last = None
    for g in _GAP.finditer(text, s, core):
        last = g
    if last:
        return last.end()                       # right after the break = already a boundary
    start = s
    if start > 0 and not text[start - 1].isspace() and not text[start].isspace():
        while start < core and not text[start].isspace():
            start += 1                           # skip the partial leading word
        while start < core and text[start].isspace():
            start += 1                           # ... and the whitespace after it
    return start


def _snap_right(text: str, e: int, core_end: int) -> int:
    """Choose the right edge within the margin (core_end, e], where `core_end` is the
    end of the matched content (never trimmed before). If a section break falls in the
    margin, end at the FIRST one; otherwise snap back off any partial trailing word."""
    g = _GAP.search(text, core_end, e)
    if g:
        return g.start()                         # right before the break = a boundary
    end = e
    if end < len(text) and not text[end - 1].isspace() and not text[end].isspace():
        while end > core_end and not text[end - 1].isspace():
            end -= 1                             # back up off the partial trailing word
    return end


def _truncate(s: str, limit: int) -> str:
    """Safety cap for an over-long merged block: keep head + tail, snapped to whitespace
    so the head/tail joins do not split a word."""
    if len(s) <= limit:
        return s
    half = limit // 2
    i = half
    while i > 0 and not s[i - 1].isspace():
        i -= 1
    j = len(s) - half
    while j < len(s) and not s[j].isspace():
        j += 1
    return s[:i].rstrip() + " [...] " + s[j:].lstrip()


def _cut_snippets(text: str, cfg: TaskConfig):
    """Turn ONE note into a list of context snippets, one per merged concept-regex hit.

    Each match gets a +/- snip_chars character window; overlapping/adjacent windows are merged
    so nearby hits share context instead of fragmenting. Every merged block's OUTER edges are
    trimmed by _snap_left/_snap_right (snap to whitespace + stop at a 3+ newline section break)
    and the block is length-capped by _truncate.

    When a note yields more than max_snips_per_note snippets, we do NOT just take the first N
    (which biases toward the top of the note). We keep every PRIORITY snippet first (the
    decisive evidence), then RANDOMLY sample the remaining snippets to fill the cap. The RNG is
    seeded from the note text so the pick is deterministic/reproducible, and note order is
    preserved in the returned list."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    # Track each hit as [window_start, window_end, match_start, match_end]. Carrying the
    # match bounds through the merge lets snapping trim the MARGINS only, never the match
    # (and stays correct when a window is clamped at the start/end of the note).
    hits = []
    for m in cfg._concept.finditer(text):
        hits.append([max(0, m.start() - cfg.snip_chars), min(len(text), m.end() + cfg.snip_chars),
                     m.start(), m.end()])
        if len(hits) >= _MAX_HITS_PER_NOTE:
            break
    if not hits:
        return []
    hits.sort()
    merged = [hits[0]]
    for ws, we, ms, me in hits[1:]:
        b = merged[-1]
        if ws <= b[1]:                # overlapping/adjacent windows -> one block
            b[1] = max(b[1], we)      # widest window end
            b[3] = max(b[3], me)      # rightmost match end (b[2] stays leftmost match start)
        else:
            merged.append([ws, we, ms, me])
    # Materialize every merged block's snippet (edges snapped, length-capped).
    snips = []
    for ws, we, ms, me in merged:
        left = _snap_left(text, ws, ms)
        right = _snap_right(text, we, me)
        snip = _truncate(text[left:right].strip(), cfg.max_snip_len)
        if snip:
            snips.append(snip)
    if len(snips) <= cfg.max_snips_per_note:
        return snips
    # Over the per-note cap: priority snippets first, then a random sample of the rest.
    cap = cfg.max_snips_per_note
    rng = random.Random(_note_seed(text))
    prio = [i for i, s in enumerate(snips) if cfg._priority and cfg._priority.search(s)]
    if len(prio) >= cap:
        chosen = rng.sample(prio, cap)                      # too many anchors: sample among them
    else:
        pset = set(prio)
        nonprio = [i for i in range(len(snips)) if i not in pset]
        chosen = prio + rng.sample(nonprio, cap - len(prio))
    return [snips[i] for i in sorted(chosen)]                # keep note order


def _dedup_key(s: str, mode: str) -> str:
    """Build the key used to detect duplicate snippets. "exact" only normalizes case and
    whitespace; "normalized" additionally replaces short (1-3 digit) numbers with '#', so
    copy-forward blocks differing only in a lab value/vital/dose collapse to one -- while
    4-digit years (the diagnosis-date signal) survive and keep genuinely distinct snippets
    distinct."""
    if mode == "exact":
        return _WS.sub(" ", s.lower()).strip()
    return _WS.sub(" ", _SHORTNUM.sub("#", s.lower())).strip()


def _ignored(snip: str, cfg: TaskConfig) -> bool:
    """Decide whether ignore_regex drops this snippet. In "snippet" scope ANY ignore hit
    drops it (blunt: an unrelated screening phrase anywhere in a wide window kills a real
    mention). In "match" scope it is dropped only when EVERY concept match is within
    ignore_radius of an ignore hit -- so a terse true positive ("colon cancer" on a problem
    list) survives even if "family history" appears elsewhere in the same snippet, while a
    pure "screening for colon cancer" (its only cancer match sits next to the screening cue)
    is still dropped."""
    ig = [(m.start(), m.end()) for m in cfg._ignore.finditer(snip)]
    if not ig:
        return False
    if cfg.ignore_scope != "match":
        return True
    for cm in cfg._concept.finditer(snip):
        c = (cm.start() + cm.end()) // 2
        if not any(a - cfg.ignore_radius <= c <= b + cfg.ignore_radius for a, b in ig):
            return False   # a clean, non-ignored on-target mention -> keep the snippet
    return True            # every on-target mention is ignore-adjacent -> drop


def _build_pool(rows, cfg: TaskConfig):
    """Turn a patient's raw note rows into the deduplicated, chronologically-sorted snippet
    "pool" that replicate selection draws from. For each dated note it cuts snippets, drops
    exact/near duplicates via _dedup_key, tags each snippet with its note date and a priority
    flag, and applies ignore_regex via _ignored (unless the snippet is priority, which overrides
    ignore). Returns records sorted oldest -> newest."""
    pool, seen = [], set()
    for row in rows:
        dt = _parse_dt(row["NoteDateTime"])
        if dt is None:
            continue
        label = dt.strftime(cfg.date_strftime)
        for snip in _cut_snippets(row["ReportText"], cfg):
            key = _dedup_key(snip, cfg.dedup)
            if key in seen:
                continue
            priority = bool(cfg._priority and cfg._priority.search(snip))
            if cfg._ignore and not priority and _ignored(snip, cfg):
                continue
            seen.add(key)
            pool.append({"text": snip, "sortkey": dt, "label": label, "priority": priority})
    pool.sort(key=lambda r: r["sortkey"])
    return pool


# --------------------------------------------------------------------------
# Replicate selection.
# --------------------------------------------------------------------------
def _char_cap(records, cfg: TaskConfig):
    """Enforce the per-input character budget as a final safety net after selection. Drops
    NON-priority snippets nearest the middle of the timeline first -- preserving the recent/
    distant endpoints and every priority anchor -- until the total is under char_budget."""
    if cfg.char_budget <= 0:
        return records
    recs = list(records)
    floor = cfg.n_recent + cfg.n_distant
    total = sum(len(r["text"]) + 48 for r in recs)
    while total > cfg.char_budget and len(recs) > floor:
        mid = len(recs) // 2
        cand = [i for i, r in enumerate(recs) if not r["priority"]]
        if not cand:
            break
        drop = min(cand, key=lambda i: abs(i - mid))
        total -= len(recs[drop]["text"]) + 48
        recs.pop(drop)
    return recs


def _select_replicates(pool, cfg: TaskConfig, n_reps: int, seed_base: int):
    """Return n_reps snippet lists. Anchors are shared; the fill is COMPLEMENTARY:
    within each timeline slice every replicate gets a different snippet, so the
    replicates overlap minimally and their union spans the most history."""
    n, budget = len(pool), cfg.snippet_budget
    if n <= budget:
        base = _char_cap(pool, cfg)
        return [list(base) for _ in range(n_reps)]

    prio = [i for i, r in enumerate(pool) if r["priority"]][: cfg.priority_cap]
    recent = list(range(max(0, n - cfg.n_recent), n))
    distant = list(range(0, min(cfg.n_distant, n)))
    anchors = sorted(set(prio + recent + distant))
    aset = set(anchors)
    middle = [i for i in range(n) if i not in aset]
    remaining = budget - len(anchors)

    per_rep = [list(anchors) for _ in range(n_reps)]
    if remaining <= 0:
        # More anchors than the budget: hand each replicate a distinct down-sample.
        for r in range(n_reps):
            per_rep[r] = sorted(random.Random(seed_base + r).sample(anchors, budget))
    elif middle:
        nbins = min(remaining, len(middle))
        m = len(middle)
        for b in range(nbins):
            items = middle[b * m // nbins:(b + 1) * m // nbins]
            if not items:
                continue
            order = items[:]
            random.Random(seed_base + b).shuffle(order)
            for r in range(n_reps):
                per_rep[r].append(order[r % len(order)])

    return [_char_cap([pool[i] for i in sorted(set(idxs))], cfg) for idxs in per_rep]


# --------------------------------------------------------------------------
# Formatting + output.
# --------------------------------------------------------------------------
def _format(records, cfg: TaskConfig, pool) -> str:
    """Render one patient input as a SINGLE line for llama-data-extraction's --file format:
    an optional `[Timeline: showing excerpts X-Y ...]` orientation header, each snippet wrapped
    with its note date, then the task question. All real newlines are escaped to \\n so the whole
    input occupies exactly one physical line (paired 1:1 with an IDs line). `pool` is the patient's
    full oldest->newest snippet list; `records` is the (date-sorted) subset shown on this line."""
    parts = []
    if cfg.header and records:
        span = f"{pool[0]['label']} to {pool[-1]['label']}"
        if cfg.mode == "chunk":
            # Contiguous slice: report the excerpt positions this chunk covers and their date range.
            pos = {id(r): i for i, r in enumerate(pool)}
            idx = [pos[id(r)] for r in records]
            parts.append(f"[Timeline: showing excerpts {min(idx) + 1}-{max(idx) + 1} of {len(pool)} total relevant excerpts, "
                         f"capturing {records[0]['label']} to {records[-1]['label']}, "
                         f"of a total patient timeline spanning {span}]\n")
        else:
            # Consensus: excerpts are a scattered sample, so report the count over the full timeline.
            noun = "excerpt" if len(records) == 1 else "excerpts"
            if len(pool) == len(records):
                parts.append(f"[Timeline: showing all {len(records)} distinct relevant {noun} "
                         f"spanning {span}]\n")
            else:
                parts.append(f"[Timeline: showing a subset of {len(records)} of the {len(pool)} total distinct relevant {noun} "
                         f"spanning {span}]\n")

    for r in records:
        parts.append(f"\n<<<\nNote date ({cfg.date_label}): {r['label']}\nNote text:\n{r['text']}\n>>>\n")
    body = "".join(parts)
    if cfg.question:
        body += "\n" + cfg.question + "\n"
    return body.replace("\n", "\\n")


def _stable_seed(pid: str, base: int) -> int:
    """Deterministic per-patient RNG seed = md5(PatientID) + base. Makes replicate sampling
    reproducible across runs and independent of processing order, yet different per patient
    and globally shiftable via --seed."""
    return (int(hashlib.md5(pid.encode("utf-8")).hexdigest(), 16) + base) % (2**31)


def _write_metadata(outdir: Path, cfg: TaskConfig, args, n_reps: int):
    """Write run_metadata.json capturing the EXACT parameters that produced this output:
    every TaskConfig field (all regexes, budgets, windows, dedup/mode) plus the runtime
    args (source, replicates, seed, effective snippet budget). The private compiled-pattern
    fields (name starts with '_') are skipped -- their source strings are already captured.
    This is the reproducibility record: the inputs are fully determined by it + the notes."""
    cfg_params = {f.name: getattr(cfg, f.name) for f in fields(cfg) if not f.name.startswith("_")}
    meta = {
        "task": cfg.name,
        "script": f"extract_{cfg.name}.py",
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "source": {"buckets": args.buckets, "notes": args.notes},
        "replicates": n_reps,
        "seed": args.seed,
        "config": cfg_params,
    }
    (outdir / "run_metadata.json").write_text(
        json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def _iter_source(args):
    """Dispatch to the bucket reader or the single-CSV reader depending on which CLI source
    (--buckets or --notes) was given."""
    if args.buckets:
        yield from _iter_buckets(Path(args.buckets))
    else:
        yield from _iter_single_csv(Path(args.notes))


def parse_args(cfg: TaskConfig):
    """Define and parse the CLI shared by every task script: the note source (--buckets XOR
    --notes, one required), --out-dir, --replicates, --seed, and a --limit override for the
    snippet budget."""
    ap = argparse.ArgumentParser(description=f"Build {cfg.name} LLM inputs from IBD/CRC notes.")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--buckets", help="dir of v2 bucket_*.csv.gz")
    src.add_argument("--notes", help="single notes CSV (PatientID,NoteDateTime,NoteID,ReportText)")
    ap.add_argument("--out-dir", default=f"{cfg.name}_inputs")
    ap.add_argument("--replicates", type=int, default=3, help="distinct inputs per patient (default 3)")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--limit", type=int, default=0, help="override snippet_budget (0 = default)")
    return ap.parse_args()


def run(cfg: TaskConfig):
    """Entry point every task script calls. Compiles the config, opens the N replicate
    inputs_k.txt / IDs_k.txt files, then for each patient builds the snippet pool and writes
    one line per replicate -- either full-coverage chunking (mode="chunk", identical files) or
    the complementary consensus subsample (mode="consensus", distinct files). Writes a per-run
    summary to stderr."""
    cfg.compile()
    args = parse_args(cfg)
    if args.limit > 0:
        cfg.snippet_budget = args.limit
    outdir = Path(args.out_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    n_reps = args.replicates
    _write_metadata(outdir, cfg, args, n_reps)   # reproducibility record, written up front

    in_w = [(outdir / f"inputs_{r + 1}.txt").open("w", encoding="utf-8") for r in range(n_reps)]
    id_w = [(outdir / f"IDs_{r + 1}.txt").open("w", encoding="utf-8") for r in range(n_reps)]

    # Audit of silent drops: patients that were pulled (so they matched the SQL/FTS terms)
    # but produced zero snippets here -> a regex-recall miss, invisible without this file.
    # And, for tasks with a priority rule, patients kept but WITHOUT any priority anchor ->
    # the decisive field (e.g. diagnosis year) is at risk. Written incrementally (no memory).
    no_snip_w = (outdir / "audit_no_snippets.txt").open("w", encoding="utf-8")
    no_prio_w = (outdir / "audit_no_priority.txt").open("w", encoding="utf-8") if cfg._priority else None

    n_seen = n_pts = n_lines = n_dropped = n_noprio = n_nodate = 0
    for pid, rows in _iter_source(args):
        n_seen += 1
        if n_seen % 2000 == 0:
            _progress(f"  processing... {n_seen:,} patients seen, {n_pts:,} kept, {n_dropped:,} dropped")
        pool = _build_pool(rows, cfg)
        if not pool:
            # Distinguish the two drop reasons so a systemic problem is obvious: a patient whose
            # notes ALL have an unparseable date (a format/schema issue -> the whole run is bad)
            # vs one with dates but no concept match (a genuine negative). Re-parsing only the
            # dropped patients' dates is cheap relative to snippet cutting.
            if not any(_parse_dt(r["NoteDateTime"]) for r in rows):
                n_nodate += 1
            no_snip_w.write(f"{pid}\n")
            n_dropped += 1
            continue
        n_pts += 1
        if no_prio_w is not None and not any(r["priority"] for r in pool):
            no_prio_w.write(f"{pid}\n")
            n_noprio += 1
        if cfg.mode == "chunk":
            # One patient spans several inputs; tag each with "<PatientID>_<n>_of_<N>_chunks"
            # so every chunk is a distinct, resumable ID downstream (skip already-run chunks)
            # while the base PatientID is still recoverable by stripping the _n_of_N_chunks suffix.
            n_chunks = (len(pool) + cfg.chunk_size - 1) // cfg.chunk_size
            for ci in range(n_chunks):
                chunk = pool[ci * cfg.chunk_size:(ci + 1) * cfg.chunk_size]
                line = _format(chunk, cfg, pool)
                cid = f"{pid}_{ci + 1}_of_{n_chunks}_chunks"
                for r in range(n_reps):
                    in_w[r].write(line + "\n")
                    id_w[r].write(f"{cid}\n")
                n_lines += 1
        else:
            for r, recs in enumerate(_select_replicates(pool, cfg, n_reps, _stable_seed(pid, args.seed))):
                in_w[r].write(_format(recs, cfg, pool) + "\n")
                id_w[r].write(f"{pid}\n")
            n_lines += 1

    for w in in_w + id_w + [no_snip_w] + ([no_prio_w] if no_prio_w else []):
        w.close()

    summary = (f"[{cfg.name}] {n_seen:,} patients seen | {n_pts:,} kept "
               f"({n_lines:,} rows/replicate x {n_reps} replicates) | "
               f"{n_dropped:,} dropped (no snippet, see audit_no_snippets.txt; "
               f"of these {n_nodate:,} had NO parseable note date -- a date-format problem if high)")
    if cfg._priority:
        summary += f" | {n_noprio:,} kept without a priority anchor (audit_no_priority.txt)"
    (outdir / "audit_summary.txt").write_text(summary + "\n", encoding="utf-8")
    _logline(summary)
