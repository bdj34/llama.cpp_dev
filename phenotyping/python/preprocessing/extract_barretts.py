#!/usr/bin/env python3
"""
extract_barretts.py -- inputs for the `barretts` task (patient-level Barrett's ascertainment).

PATIENT-level, from free text -- the complement to the event-level egd_detailed_extraction.
That task answers "what did THIS EGD find" from a report + pathology; this one answers "does
this patient have Barrett's at all, since when, and how long is the segment" from the
whole note history. It therefore also catches patients whose Barrett's is documented only in
narrative -- an outside EGD, or one whose CPT/pathology never reached the extract -- which the
event pipeline cannot see.

Membership regex anchors on the Barrett's vocabulary broadly: the term itself (incl. the common
one-t "Barret" misspelling), columnar-lined esophagus, intestinal metaplasia, salmon-coloured
mucosa, the Prague C&M notation -- plus esophageal adenocarcinoma and the Barrett's-directed
treatments (ablation / EMR / esophagectomy), since "s/p RFA for Barrett's" is often the only
place the diagnosis appears.

Priority (kept in every replicate) = a snippet co-locating a Barrett's term with a decisive
cue: a diagnosis or biopsy statement, or a date. Looser than the IBD rule (term + cue + date)
on purpose -- the snippet that establishes the diagnosis and the one carrying its YEAR are
often not the same snippet, so requiring both in one would lose the diagnosis entirely.

    ./extract_barretts.py --buckets /data/note_buckets --out-dir /data/barretts/raw_inputs
"""
from snippet_lib import TaskConfig, run

# The diagnosis itself. "barret\w*" covers Barret / Barrett / Barretts / Barrett's in one stem.
BE_CORE = (
    r"barret\w*|"
    r"columnar[- ]?lined\s+o?esophag\w*|"
    r"intestinal\s+metaplasia|"
    r"salmon[- ]?colou?red|salmon[- ]?(?:appearing\s+)?mucosa|"
    r"prague\b|\bC\d+\s?M\d+\b"
)
# The endpoint. Reached only through Barrett's, so an EAC mention is Barrett's evidence.
EAC = r"o?esophageal\s+(?:adeno)?carcinoma|adenocarcinoma\s+of\s+the\s+o?esophagus|(?-i:\bEAC\b)"
# Barrett's-directed treatment. Often the ONLY place the diagnosis is named ("s/p RFA").
# NOTE: bare RFA also means cardiac/hepatic ablation -- kept for recall, drop it if the
# snippet budget is being eaten by cardiology notes.
TX = (
    r"radiofrequency\s+ablation|(?-i:\bRFA\b)|halo\s*(?:90|360)|cryoablation|cryotherapy|"
    r"endoscopic\s+mucosal\s+resection|endoscopic\s+submucosal\s+dissection|o?esophagectom\w*"
)
BE_TERM = rf"{BE_CORE}|{EAC}|{TX}"

CONFIG = TaskConfig(
    name="barretts",

    # WHICH notes/snippets to pull: the Barrett's vocabulary, its endpoint, and its treatments.
    concept_regex=rf"(?i)(?:{BE_TERM})",

    # WHICH snippets are decisive and must appear in every replicate: a Barrett's term
    # co-located with a diagnosis-or-biopsy statement or a date.
    priority_regex=(
        rf"\A(?=.*(?:{BE_CORE}|{EAC}))"
        r"(?=.*(?:diagnos|dx\b|biops|patholog|s/?p\b|status\s+post|history\s+of|hx\s+of|"
        r"surveillance|\d+\s*cm\b|(?:19|20)\d{2}|\d{1,3}\s*(?:years?|yrs?)\s+ago))"
    ),

    question=(""),

    snip_chars=280,          # Prague length / year usually sit a line or two from the term
    max_snips_per_note=12,   # cap snippets from a single note
    snippet_budget=50,       # max snippets per input; above this we subsample -> distinct inputs
    char_budget=75000,       # hard safety cap on snippet chars per input
    n_recent=8,              # newest snippets: current surveillance status / latest EGD
    n_distant=12,            # oldest snippets: the ORIGINAL diagnosis year lives here
    priority_cap=22,         # at most this many priority anchors
    dedup="normalized",      # collapse copy-forward repeats differing only in short numbers
)

if __name__ == "__main__":
    run(CONFIG)
