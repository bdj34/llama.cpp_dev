#!/usr/bin/env python3
"""
extract_colectomy.py -- inputs for the `colectomy` task.

Yes/no + procedure type + segments removed + month/year. Concept regex mirrors the
surgical vocabulary: colectomy variants (procto/hemi/rectosigmoid/ileocecal/subtotal/
total/segmental/partial), sigmoidectomy/proctectomy/proctocolectomy/ileocecectomy,
abdominoperineal resection (APR), low anterior resection (LAR), colon/rectum/bowel
resection-or-removal (either word order), Hartmann, ileostomy/colostomy, anastomosis,
and J-pouch / IPAA / pouch creation.

Priority (kept in every replicate) = evidence the operation actually happened: a
resection/ostomy/pouch term co-occurring with s/p, status-post, underwent, performed,
post-op, POD#, "history of", or a year. Mere discussion ("candidate for colectomy")
fills the remaining budget.

    ./extract_colectomy.py --buckets /data/note_buckets --out-dir /data/colectomy/raw_inputs
"""
from snippet_lib import TaskConfig, run

SEG    = r"(?:procto|hemi|recto\s?sigmoid|ileocec|subtotal|total|segmental|partial)"
ORGAN  = r"\b(?:colon|rect\w*|cecum|sigmoid|bowel|ileocecal)"
REMOVE = r"(?:resect|remov|excis)\w*"
PROC = (
    rf"{SEG}?\s*colectom\w*|"                     # (hemi/procto/subtotal...)colectomy
    r"(?:sigmoid|proct|ileocec)ectom\w*|"         # sigmoidectomy, proctectomy, ileocecectomy
    r"abdominoperineal\s+resection|"             # APR spelled out (bare "APR" dropped: matched the month)
    r"low\s+anterior\s+resection|(?-i:\bLAR\b)|"     # LAR (case-sensitive; common rectal resection)
    rf"{ORGAN}.{{0,20}}?{REMOVE}|"                # "sigmoid colon was resected", "cecum removed"
    rf"{REMOVE}.{{0,20}}?{ORGAN}|"                # reverse order: "resection of the sigmoid colon"
    r"hartmann\w*|(?:ileostom|colostom)\w*|anastomos\w*|"  # Hartmann / ostomy / anastomosis
    r"j[- ]?pouch|\bipaa\b|pouch\s+(?:construction|creation)"  # ileal-pouch reconstruction
)

CONFIG = TaskConfig(
    name="colectomy",

    # WHICH notes/snippets to pull: surgical vocabulary for colon/rectal removal.
    concept_regex=rf"(?i)(?:{PROC})",

    # WHICH snippets are "decisive" and must appear in every one of the 3 inputs: a
    # resection/ostomy/pouch term co-located with evidence the operation HAPPENED
    # (s-p / status post / underwent / performed / post-op / POD / history of / a year).
    # This separates a done procedure from mere discussion ("candidate for colectomy").
    priority_regex=(
        r"\A(?=.*(?:ectom\w|resect|ostom|hartmann|pouch))"
        r"(?=.*(?:s/?p\b|status\s+post|underwent|performed|post[- ]?op|\bpod\b|"
        r"history\s+of|hx\s+of|(?:19|20)\d{2}|\d{1,3}\s*(?:years?|yrs?)\s+ago))"
    ),

    # Instruction appended once at the END of every input, after the snippets.
    question=(""
        # "Question: Using only these notes, determine whether any part of the colon or rectum "
        # "was surgically REMOVED, and if so the procedure type, which segments were removed, and "
        # "the month and year of the procedure."
    ),

    snip_chars=260,          # tighter window: procedure type/segments/date sit close to the hit,
                             # and the small-active-param models (A4B/A3B) do better with less noise
    max_snips_per_note=12,   # cap snippets from a single note
    snippet_budget=35,       # smaller budget: colectomy is a single event, not a long course
    char_budget=50000,       # hard safety cap on snippet chars per input
    n_recent=6,              # newest snippets always kept (recent op / current surgical status)
    n_distant=6,             # oldest snippets always kept (an old surgery may predate the record)
    priority_cap=20,         # at most this many priority anchors
    dedup="normalized",      # collapse copy-forward repeats differing only in short numbers; keep years
)

if __name__ == "__main__":
    run(CONFIG)
