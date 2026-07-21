"""
combined_step2_make_snippets.py

Reads the patient-hash bucket CSVs written by combined_step1_pull_notes.R
ONE bucket at a time. Because R hashed every note by PatientID, a bucket
holds all notes for its patients, so this groups by patient and emits
one per-patient record (all of that patient's concept snippets, in
chronological order) per pipeline -- without ever loading the whole
corpus. Output: <pipeline>_patients.jsonl, ready for LLM phenotyping.

The regex anchors below MIRROR the SQL FullTextSearch terms (keep the
two in sync!) so every note the SQL pulled yields >= 1 snippet. They
also re-add forms the FTS index cannot represent (e.g. literal "u.c.").
A note contributes to a pipeline iff its concept regex yields a snippet.
"""

import json
import re
from collections import defaultdict
from pathlib import Path

import pandas as pd

BUCKET_DIR = Path("note_buckets")
OUT_DIR = Path("snippets")
SNIP_CHARS = 300          # characters kept on each side of a match
MAX_SNIPPETS_PER_NOTE = 20

# ---------------------------------------------------------------------
# Safe CSV read (matches how R wrote the files):
#   * dtype=str + keep_default_na=False: pandas will NOT turn note text
#     like "NA", "null", "None" into NaN, and IDs stay exact strings.
#   * The C engine handles embedded (quoted) newlines in ReportText.
# ---------------------------------------------------------------------
READ_KWARGS = dict(dtype=str, keep_default_na=False, na_values=[], encoding="utf-8")

# ---------------------------------------------------------------------
# Concept anchors -- mirror the SQL terms, plus regex-only recoveries.
# NEAR(a, b, 10) is approximated as a .. b within ~90 chars either order
# (10 terms ~ <= 90 chars); ordered NEARs use a single direction.
# ---------------------------------------------------------------------
def _near(a, b, chars=90, ordered=False):
    fwd = rf"{a}\W(?:.{{0,{chars}}}?){b}"
    if ordered:
        return fwd
    return rf"(?:{fwd}|{b}\W(?:.{{0,{chars}}}?){a})"

CONCEPT_PATTERNS = {
    "ibd_core": [
        r"\bcrohn\w*",
        _near(r"\bulcerative", r"(?:colitis|proctocolitis|proctitis)\b", ordered=True),
        r"\bu\.?\s?c\.?\b",          # uc, u.c. (regex-only recovery)
        r"\bc\.?\s?u\.?\s?c\.?\b",   # cuc, c.u.c.
        r"\binflammatory bowel d(?:isease|z)\b",
        r"\bibd\b",
        _near(r"\bchronic", r"(?:colitis|proctitis|proctocolitis)\b"),
    ],
    "colo_findings": [
        _near(r"\bcolonoscop\w*", r"findings?\b"),
    ],
    "colonoscopy": [
        r"\bcolonoscop\w*",
    ],
    "colectomy": [
        r"\b(?:procto|hemi|rectosigmoid|ileocec)?colectom\w*",
        r"\b(?:sigmoidectom|proctectom|ileocecectom)\w*",
        _near(r"\b(?:colon|rect(?:um|al)|ileocecal)\b", r"\b(?:resect|remov)\w*"),
        r"\bhartmann\w*",
        r"\b(?:ileostom|colostom|anastomos)\w*",
        r"\bpouch construction\b",
        r"\bj[- ]?pouch\b",
        r"\bipaa\b",
    ],
    "crc": [
        r"\b(?:colorectal|rectal|colon)\s+cancer\b",
        r"\bcrc\b",
    ],
}

# Snippet-level negation for CRC (finer than the SQL note-level AND NOT):
# a snippet whose match is screening/surveillance context is dropped.
CRC_NEGATION = re.compile(
    r"(?:cancer|crc)\s+(?:screening|surveillance)|"
    r"(?:screen(?:ing)?|surveillance)\s+for\s+(?:colorectal|colon|rectal)\s+cancer",
    re.IGNORECASE,
)

PIPELINES = {
    # pipeline -> concepts whose regex anchors define membership + snippets.
    # No SQL flags: a note belongs to a pipeline iff its concept regex
    # yields >= 1 snippet (notes with none are skipped below).
    "IBD_diagnosis":      ["ibd_core", "colo_findings"],
    "IBD_diagnosis_year": ["ibd_core"],
    "colonoscopy_timing": ["colonoscopy"],
    "colectomy":          ["colectomy"],
    "CRC_from_free_text": ["crc"],
}

COMPILED = {
    c: re.compile("|".join(pats), re.IGNORECASE | re.DOTALL)
    for c, pats in CONCEPT_PATTERNS.items()
}


def cut_snippets(text, concepts, snip=SNIP_CHARS):
    """Windows of +/- snip chars around each match, overlaps merged."""
    spans = []
    for c in concepts:
        for m in COMPILED[c].finditer(text):
            if c == "crc" and CRC_NEGATION.search(
                text[max(0, m.start() - 60): m.end() + 60]
            ):
                continue
            spans.append((max(0, m.start() - snip), min(len(text), m.end() + snip)))
    if not spans:
        return []
    spans.sort()
    merged = [list(spans[0])]
    for s, e in spans[1:]:
        if s <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])
    return [text[s:e].strip() for s, e in merged[:MAX_SNIPPETS_PER_NOTE]]


def main():
    OUT_DIR.mkdir(exist_ok=True)
    writers = {p: (OUT_DIR / f"{p}_patients.jsonl").open("w", encoding="utf-8")
               for p in PIPELINES}

    # One bucket at a time: a bucket holds ALL notes for its patients
    # (R hashed by PatientID), so we can group by patient and emit one
    # concatenated record per patient without ever holding the full
    # corpus in RAM. Bucket size is controlled by N_BUCKETS in the R step.
    #
    # R writes one gzip SHARD per window per bucket, named
    # "bucket_NN__<window>.csv.gz", so a bucket = all shards sharing the
    # "bucket_NN" prefix. Group the shards, then read+concat each bucket.
    shards = defaultdict(list)
    for p in BUCKET_DIR.glob("bucket_*.csv.gz"):
        shards[p.name.split("__")[0]].append(p)   # key = "bucket_NN"

    for bucket, paths in sorted(shards.items()):
        # read_csv infers gzip from the .gz extension
        df = pd.concat([pd.read_csv(p, **READ_KWARGS) for p in sorted(paths)],
                       ignore_index=True)
        # Dedup: a note can appear in >1 shard only if a window was rerun
        # after a partial write; also guards cross-concept duplicates.
        df = df.drop_duplicates(subset="NoteID")
        df = df.sort_values(["PatientID", "NoteDateTime"])

        for pid, pdf in df.groupby("PatientID", sort=False):
            for pipeline, concepts in PIPELINES.items():
                parts = []
                for row in pdf.itertuples(index=False):
                    snips = cut_snippets(row.ReportText, concepts)
                    if snips:
                        parts.append((row.NoteID, row.NoteDateTime,
                                      "\n...\n".join(snips)))
                if not parts:
                    continue  # patient has no note matching this concept
                # All of the patient's snippets, chronological, for the LLM
                writers[pipeline].write(json.dumps({
                    "PatientID": pid,
                    "n_notes": len(parts),
                    "notes": [{"NoteID": n, "NoteDateTime": d, "text": t}
                              for n, d, t in parts],
                }) + "\n")
        print(f"done {bucket} ({len(paths)} shards)")
    for w in writers.values():
        w.close()


if __name__ == "__main__":
    main()
