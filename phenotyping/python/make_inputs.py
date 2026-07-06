#!/usr/bin/env python3
"""
Consolidated, config-driven preprocessor for the phenotyping pipeline.

Replaces the near-identical reproduce_results/*/step2_process_*.py scripts. For ONE pass of
ONE task it:
  1. reads notes.csv (from db_pull.py),
  2. extracts regex-anchored snippets per patient (recent + random + earliest selection),
  3. writes, per model *family*, the files llama-data-extraction consumes:
        <out>/<family>/system.txt   shared instruction prefix (chat-wrapped, cached once)
        <out>/<family>/input.txt    one newline-escaped line per patient (excerpts + assistant opener)
        <out>/<family>/ptIDs.txt    matching IDs

Because inference runs with --promptFormat raw, ALL chat formatting happens here, using tokens
pulled from each model's GGUF chat_template. Families are defined in CHAT_FORMATS below.

Reproducibility: random.sample is seeded (--seed).
"""
import argparse
import csv
import os
import random
import re
import sys
import zlib
from datetime import datetime

# ---------------------------------------------------------------------------
# Chat formatting per model family.
#   system_open : text that begins the (cached) shared prefix, right AFTER the BOS token
#                 (llama-data-extraction tokenizes the system prompt with add_special=True,
#                 so DO NOT include an explicit <bos> here).
#   turn_close_open : closes the user turn and opens the assistant turn; appended to each input.
#
# !!! VERIFY these against each GGUF: `gguf-dump <file> | grep -A2 chat_template` !!!
# 2026 models (Gemma-4, Qwen3.6) — confirm the exact control tokens before the first real run.
# ---------------------------------------------------------------------------
CHAT_FORMATS = {
    # Gemma family: single user turn (no system role); instructions live in the user turn.
    "gemma4": {
        "system_open": "<start_of_turn>user\n",
        "turn_close_open": "<end_of_turn>\n<start_of_turn>model\n",
    },
    # Qwen/ChatML family.
    "qwen": {
        "system_open": "<|im_start|>user\n",
        "turn_close_open": "<|im_end|>\n<|im_start|>assistant\n",
    },
}


def merge_indices(indices, last_line, expand_before, expand_after):
    """Merge nearby matched line indices into [start, end] blocks (ported from step2)."""
    if not indices:
        return []
    indices.sort()
    merged = [[indices[0] - expand_before, indices[0] + expand_after]]
    for idx in indices[1:]:
        if idx - merged[-1][1] <= expand_before + expand_after:
            merged[-1][1] = idx + expand_after
        else:
            merged.append([idx - expand_before, idx + expand_after])
    return [[max(0, s), min(last_line, e)] for s, e in merged]


def extract_excerpts(notes, myregex, lines_before, lines_after, max_excerpts_per_note):
    """Return {patient_id: [excerpt_str, ...]} anchored on regex matches."""
    excerpts, seen = {}, {}
    for note in notes:
        pid = note["PatientID"]
        text = note["ReportText"].replace("\r\n", "\n").replace("\r", "\n")
        edt = note.get("EntryDateTime", "NULL")
        if edt in (None, "", "NULL"):
            continue
        try:
            entry_date = datetime.strptime(edt, "%Y-%m-%d %H:%M:%S").strftime("%Y-%m")
        except ValueError:
            entry_date = edt[:7]

        matches = [(m.start(), m.end()) for m in re.finditer(myregex, text, flags=re.IGNORECASE)]
        if not matches:
            continue

        lines = text.split("\n")
        offsets = [0]
        for ln in lines:
            offsets.append(offsets[-1] + len(ln) + 1)
        match_lines = set()
        for start, end in matches:
            first = max(0, next((i for i in range(len(offsets) - 1) if offsets[i] > start), 1) - 1)
            last = next((i for i in range(len(offsets) - 1) if offsets[i] >= end), len(lines))
            match_lines.update(range(first, last))

        blocks = merge_indices(sorted(match_lines), len(lines), lines_before, lines_after)
        excerpts.setdefault(pid, [])
        seen.setdefault(pid, set())
        for start, end in blocks[:max_excerpts_per_note]:
            chunk = "\n".join(lines[start:end + 1])
            key = chunk.strip().lower()
            if key in seen[pid]:
                continue
            seen[pid].add(key)
            excerpts[pid].append(f"\n<<<\nNote date (YYYY-MM): {entry_date}\nNote text:\n{chunk}\n>>>\n")
    return excerpts


def select_and_join(patient_excerpts, limit, n_recent, n_distant, question):
    """Pick recent + random + earliest excerpts (seeded), append the question."""
    patient_excerpts.sort()
    if len(patient_excerpts) <= limit:
        chosen = patient_excerpts
    else:
        recent = patient_excerpts[-n_recent:]
        distant = patient_excerpts[:n_distant]
        middle = patient_excerpts[n_distant:-n_recent]
        k = max(0, limit - n_recent - n_distant)
        rnd = random.sample(middle, min(k, len(middle)))
        chosen = sorted(recent + rnd + distant)
    body = "".join(chosen)
    if question:
        body += "\n" + question + "\n"
    return body


def main():
    ap = argparse.ArgumentParser()
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--sql", help="SQL file; stream notes directly from SQL Server (no notes.csv)")
    src.add_argument("--notes", help="notes.csv path (mainly for testing/offline use)")
    ap.add_argument("--out", required=True, help="output dir for this pass; <family>/ created under it")
    ap.add_argument("--families", required=True, help="comma-separated model families to emit")
    ap.add_argument("--instructions", required=True, help="plain-text instruction file (family-agnostic)")
    ap.add_argument("--regex", required=True)
    ap.add_argument("--lines-before", type=int, default=2)
    ap.add_argument("--lines-after", type=int, default=2)
    ap.add_argument("--excerpt-limit", type=int, default=20)
    ap.add_argument("--n-recent", type=int, default=5)
    ap.add_argument("--n-distant", type=int, default=5)
    ap.add_argument("--max-excerpts-per-note", type=int, default=15)
    ap.add_argument("--question", default="")
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--slices", type=int, default=1,
                    help="partition the cohort into N hash buckets; emit N input pairs "
                         "(slice0..sliceN-1). Each SQL pull fetches ~1/N of patients.")
    ap.add_argument("--force", action="store_true", help="regenerate slices even if present")
    args = ap.parse_args()
    if args.slices < 1:
        ap.error("--slices must be >= 1")

    csv.field_size_limit(sys.maxsize)

    with open(args.instructions, encoding="utf-8") as f:
        instructions = f.read().rstrip("\n")

    headers = ["PatientID", "EntryDateTime", "NoteID", "ReportText"]
    families = [x.strip() for x in args.families.split(",") if x.strip()]
    for fam in families:
        if fam not in CHAT_FORMATS:
            sys.exit(f"[make_inputs] unknown family '{fam}' (add it to CHAT_FORMATS)")

    def csv_notes(path, k, n):
        """Stream a CSV; for n>1 keep only patients in bucket k (stable crc32 partition)."""
        with open(path, encoding="utf-8-sig") as f:
            for row in csv.reader(f):
                if len(row) < len(headers):
                    continue
                if n > 1 and (zlib.crc32(row[0].encode("utf-8")) % n) != k:
                    continue
                yield dict(zip(headers, row))

    def notes_for_slice(k):
        # SQL: server-side CHECKSUM partition (pulls ~1/N). CSV: client-side crc32 (testing).
        if args.sql:
            import db  # same dir (python/); on sys.path when run as a script
            return db.iter_notes(args.sql, slice_i=k, slice_n=args.slices)
        return csv_notes(args.notes, k, args.slices)

    src = args.sql or args.notes
    for k in range(args.slices):
        slice_dirs = {fam: os.path.join(args.out, fam, f"slice{k}") for fam in families}
        # Idempotent per-slice skip (crash-resume): if every family's slice is already written,
        # don't re-pull it. Use --force to regenerate.
        if not args.force and all(
            os.path.exists(os.path.join(d, "input.txt")) and os.path.exists(os.path.join(d, "ptIDs.txt"))
            for d in slice_dirs.values()
        ):
            print(f"[make_inputs] slice {k}/{args.slices}: already present, skipping", file=sys.stderr)
            continue

        random.seed(args.seed + k)  # each slice independently reproducible
        print(f"[make_inputs] slice {k + 1}/{args.slices}: pulling from {src}", file=sys.stderr)
        excerpts = extract_excerpts(notes_for_slice(k), args.regex, args.lines_before,
                                    args.lines_after, args.max_excerpts_per_note)
        ids, bodies = [], []
        for pid, pe in excerpts.items():
            ids.append(pid)
            bodies.append(select_and_join(pe, args.excerpt_limit, args.n_recent, args.n_distant, args.question))
        print(f"[make_inputs] slice {k}: {len(ids)} patients with >=1 matched excerpt", file=sys.stderr)

        for fam in families:
            fmt = CHAT_FORMATS[fam]
            d = slice_dirs[fam]
            os.makedirs(d, exist_ok=True)
            # Shared (cached) system prefix: chat-open + instructions + the "Excerpts:" boundary.
            with open(os.path.join(d, "system.txt"), "w", encoding="utf-8") as f:
                f.write(fmt["system_open"] + instructions + "\n\nExcerpts:\n")
            # Per-patient variable part; write atomically so a crash never leaves a half file.
            with open(os.path.join(d, "input.txt.tmp"), "w", encoding="utf-8") as fi, \
                 open(os.path.join(d, "ptIDs.txt.tmp"), "w", encoding="utf-8") as fid:
                for pid, body in zip(ids, bodies):
                    fi.write((body + fmt["turn_close_open"]).replace("\n", "\\n") + "\n")
                    fid.write(f"{pid}\n")
            os.replace(os.path.join(d, "input.txt.tmp"), os.path.join(d, "input.txt"))
            os.replace(os.path.join(d, "ptIDs.txt.tmp"), os.path.join(d, "ptIDs.txt"))
        print(f"[make_inputs] slice {k}: wrote inputs for families {families}", file=sys.stderr)


if __name__ == "__main__":
    main()
