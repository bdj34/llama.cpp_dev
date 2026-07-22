#!/usr/bin/env python3
"""
extract_colectomy.py -- inputs for the `colectomy` task.

Yes/no + procedure type + segments removed + month/year. Concept regex mirrors the
surgical vocabulary: colectomy variants (procto/hemi/rectosigmoid/ileocecal/subtotal/
total/segmental/partial), sigmoidectomy/proctectomy/proctocolectomy/ileocecectomy,
abdominoperineal resection (APR), colon/rectum/bowel resection-or-removal (either word
order), Hartmann, ileostomy/colostomy, anastomosis, and J-pouch / IPAA / pouch creation.

Priority (kept in every replicate) = evidence the operation actually happened: a
resection/ostomy/pouch term co-occurring with s/p, status-post, underwent, performed,
post-op, POD#, "history of", or a year. Mere discussion ("candidate for colectomy")
fills the remaining budget.

    ./extract_colectomy.py --buckets /data/note_buckets --out-dir /data/colectomy/raw_inputs
"""
from snippet_lib import TaskConfig, run

PROC = (
    # "colectomy" with an OPTIONAL leading qualifier naming the extent/segment
    # (proctocolectomy, hemicolectomy, rectosigmoid/ileocecal/subtotal/total/segmental/partial).
    r"(?:procto|hemi|recto\s?sigmoid|ileocec|subtotal|total|segmental|partial)?\s*colectom\w*|"
    # Other "-ectomy" resections of specific segments: sigmoidectomy, proctectomy,
    # proctocolectomy, ileocecectomy.
    r"(?:sigmoid|procto|proctocol|ileocec)ectom\w*|"
    # Abdominoperineal resection (rectum + anus removed), spelled out or as the abbreviation APR.
    r"abdominoperineal\s+resection|\bapr\b|"
    # ORGAN then ACTION: a colon/rectum/bowel term followed within ~25 chars by
    # resect/remov/excis (e.g. "sigmoid colon was resected", "cecum removed").
    r"(?:colon|rect\w*|cecum|sigmoid|bowel|ileocecal)\W.{0,25}?(?:resect|remov|excis)\w*|"
    # ACTION then ORGAN: the reverse word order (e.g. "resection of the sigmoid colon").
    r"(?:resect|remov|excis)\w*\W.{0,25}?(?:colon|rect\w*|cecum|sigmoid|bowel)|"
    # Hartmann procedure; an ileostomy/colostomy (optionally "end ..."); any anastomosis
    # (the bowel reconnection that follows a resection).
    r"hartmann\w*|(?:end\s+)?(?:ileostom|colostom)\w*|anastomos\w*|"
    # Ileal-pouch reconstruction after (procto)colectomy: J-pouch, IPAA, or pouch construction/creation.
    r"j[- ]?pouch|\bipaa\b|pouch\s+(?:construction|creation)"
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
        r"(?is)(?=.*(?:colectom|proctectom|ectom\w|resect|ostom|hartmann|pouch|\bapr\b))"
        r"(?=.*(?:s/?p\b|status\s+post|underwent|performed|post[- ]?op|\bpod\b|"
        r"history\s+of|hx\s+of|(?:19|20)\d{2}|\d{1,3}\s*(?:years?|yrs?)\s+ago))"
    ),

    # Instruction appended once at the END of every input, after the snippets.
    question=(
        "Question: Using only these notes, determine whether any part of the colon or rectum "
        "was surgically REMOVED, and if so the procedure type, which segments were removed, and "
        "the month and year of the procedure."
    ),

    snip_chars=320,          # characters of context kept on EACH side of a regex hit
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
