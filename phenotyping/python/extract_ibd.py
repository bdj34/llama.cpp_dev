#!/usr/bin/env python3
"""
extract_ibd.py -- inputs for the merged `ibd` task (type + confirmation + year).

Scope is ANY IBD, not just IBD colitis: ulcerative colitis AND Crohn's disease of any
location, including ileal / small-bowel Crohn's WITHOUT colonic involvement (the grammar
has "Crohn's without colitis"). The membership regex therefore anchors on the Crohn's/UC
vocabulary broadly (bare colitis/proctitis are safe in an IBD cohort, and so are "UC"/"CUC";
Crohn's includes the common Chron's/Chrohn's misspellings) plus non-colitis Crohn's synonyms
-- (terminal) ileitis, regional enteritis, granulomatous enteritis/ileitis -- so ileal-Crohn's
evidence surfaces even in notes that do not repeat the word "Crohn's".

Priority (kept in every replicate) = a snippet that co-locates an IBD term, a diagnosis/onset
cue, AND a date -- either a 4-digit year or "N years ago" (both yield a computable diagnosis
year). This is far tighter than the old "IBD term near any number" rule (which fired on doses
and lab values).

    ./extract_ibd.py --buckets /data/note_buckets --out-dir /data/ibd/raw_inputs
"""
from snippet_lib import TaskConfig, run

# Crohn's (incl. the common Chron's/Chrohn's misspellings) + its NON-colitis synonym forms
# (the colitis forms, e.g. granulomatous colitis / ileocolitis, are caught by COLITIS below).
CROHNS  = r"(?:crohn|chron|chrohn)\w*|regional\s+enteritis|granulomatous\s+(?:enteritis|ileitis)|(?:terminal\s+)?ileitis"
# Any colitis or proctitis, bare (no qualifier required -- safe in an IBD cohort, and higher
# recall). This subsumes ulcerative / indeterminate / granulomatous / left-sided / chronic
# colitis, pancolitis, ileocolitis, proctocolitis, and ulcerative/chronic proctitis.
COLITIS = r"colitis|proctitis|proctosigmoiditis"
# UC / CUC abbreviations (spelled-out "ulcerative colitis" is already caught by COLITIS).
UC      = r"\bu\.?\s?c\.?\b|\bc\.?\s?u\.?\s?c\.?\b"
# The umbrella term itself.
IBD_GEN = r"inflammatory\s+bowel\s+d(?:isease|z)|\bibd(?:-?u)?\b"
IBD_TERM = rf"{CROHNS}|{COLITIS}|{UC}|{IBD_GEN}"

CONFIG = TaskConfig(
    name="ibd",

    # WHICH notes/snippets to pull: a note contributes only if this regex matches, and
    # each match becomes a snippet. This is the IBD vocabulary (UC + Crohn's + synonyms).
    concept_regex=rf"(?i)(?:{IBD_TERM})",

    # WHICH snippets are "decisive" and must appear in every one of the 3 inputs.
    # For IBD-year that is a snippet co-locating an IBD term + an onset/diagnosis cue +
    # a date: EITHER a 4-digit year OR "N years ago" (both resolve to a diagnosis year
    # against the note date).
    priority_regex=(
        rf"\A(?=.*(?:{IBD_TERM}))"
        r"(?=.*(?:diagnos|dx\b|onset|since|first\s+(?:seen|noted|presented|diagnosed)|"
        r"history\s+of|hx\s+of|established))"
        r"(?=.*(?:(?:19|20)\d{2}|\d{1,3}\s*(?:years?|yrs?)\s+ago))"
    ),

    # The instruction appended once at the END of every input, after the snippets. The
    # grammar/system prompt do the heavy lifting; this just states the task in-line.
    question=(""
        # "Question: Using only these notes, determine (1) whether the patient has IBD -- either "
        # "ulcerative colitis OR Crohn's disease of ANY location, including ileal/small-bowel "
        # "Crohn's with no colonic involvement, (2) the specific diagnosis/type, (3) whether it "
        # "was confirmed by endoscopy or pathology, and (4) the year of the patient's ORIGINAL "
        # "IBD diagnosis (prefer the earliest year explicitly stated)."
    ),

    snip_chars=280,          # context kept on EACH side of a hit (trimmed from 320: the dx-year
                             # cue usually sits near the IBD term, and less noise helps A4B/A3B)
    max_snips_per_note=12,   # cap snippets taken from a single note (avoids 1 note dominating)
    snippet_budget=50,       # max snippets per input; above this we subsample -> 3 distinct inputs
    char_budget=75000,       # hard safety cap on snippet chars per input (context guard)
    n_recent=5,              # newest snippets always kept in all 3 inputs (current diagnosis)
    n_distant=15,            # oldest snippets always kept in all 3 inputs (earliest = original dx)
    priority_cap=22,         # at most this many priority anchors, so they cannot crowd out the rest
    dedup="normalized",      # collapse copy-forward repeats differing only in short numbers; keep years
)

if __name__ == "__main__":
    run(CONFIG)
