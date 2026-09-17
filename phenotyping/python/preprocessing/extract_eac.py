#!/usr/bin/env python3
"""
extract_eac.py -- inputs for the `eac` task (esophageal ADENOCARCINOMA, free text).

The esophageal analogue of extract_crc.py, with one difference that drives the whole design:
in the esophagus, HISTOLOGY decides whether a cancer is in scope. Adenocarcinoma is the
endpoint of the Barrett's pathway; squamous cell carcinoma is a different disease with
different risk factors, and in a VA population it is at least as common. So the concept regex
deliberately pulls EVERY esophageal cancer mention and lets the model sort adenocarcinoma from
squamous -- filtering squamous out here would make it invisible instead of excludable.

Barrett's terms are in the membership regex too, because "barretts_associated" needs the
evidence and because EAC is frequently named only as "adenocarcinoma arising in Barrett's".
Esophagectomy is included for the same reason it is NOT in the Barrett's SQL filter: unlike RFA
or EMR it is site-specific, so it implies esophageal disease on its own.

Priority (kept in every replicate) = a cancer/Barrett's term co-located with a diagnosis, stage,
pathology, or date cue -- the snippets that carry the verdict, the year, and the stage.

    ./extract_eac.py --buckets /data/note_buckets --out-dir /data/eac/raw_inputs
"""
from snippet_lib import TaskConfig, run

# The esophagus and its junction. "o?esophag\w*" covers esophagus/esophageal and the British
# oesophagus; cardia and GEJ are included because Siewert-type junctional adenocarcinoma is the
# same disease and is often recorded as "cardia" or "GE junction".
SITE  = r"\b(?:o?esophag\w*|gastro-?o?esophageal|(?-i:\bGEJ\b)|\bGE\s+junction\b|cardia\b)"
MALIG = r"(?:adenoca\w*|(?:adeno)?carcinoma|cancer|malignan\w*|neoplas)"
# No "not followed by screen" guard here, unlike extract_crc.py. Screening language is EVIDENCE
# for this task: detection_mode separates "screen_detected" from "surveillance_detected", and the
# snippet naming the screening context is what distinguishes them. The guard also earns far less
# here -- "colorectal cancer screening" is ubiquitous boilerplate, "esophageal cancer screening"
# is not -- and SITE already keeps CRC screening reminders out.
# A site word is often preceded by a modifier -- "of the DISTAL esophagus", "of the GASTRIC
# cardia" -- which the bare "of (the) SITE" form cannot cross. MOD allows up to two such words.
# \w+\s+ cannot span punctuation, so "of the prostate. Esophagus normal" stays a non-match.
MOD = r"(?:\w+\s+){0,2}"
CANCER = (
    rf"{SITE}.{{0,20}}?{MALIG}|"   # "esophageal adenocarcinoma", "cardia cancer"
    rf"{SITE}\s+ca\b|"             # "esophageal ca" shorthand
    rf"{MALIG}\s+of\s+(?:the\s+)?{MOD}{SITE}|"    # "adenocarcinoma of the (distal) esophagus"
    rf"\bca\s+of\s+(?:the\s+)?{MOD}{SITE}|"       # "Ca of the (gastric) cardia", "Ca of the GE junction"
    r"(?-i:\bEAC\b)"
)
# Barrett's: the precursor, needed for barretts_associated and often the only naming of the EAC.
BARRETTS = r"barret\w*"
# Definitive surgery. Site-specific, so it implies esophageal disease without a cancer word.
SURG = r"o?esophagectom\w*"
EAC_TERM = rf"{CANCER}|{SURG}"

CONFIG = TaskConfig(
    name="eac",

    # WHICH notes/snippets to pull: every esophageal/junctional cancer mention, plus Barrett's
    # and esophagectomy. Squamous mentions are pulled ON PURPOSE -- the model excludes them.
    concept_regex=rf"(?i)(?:{EAC_TERM})",

    # WHICH snippets are decisive and must appear in every replicate: a cancer or Barrett's term
    # co-located with a real-diagnosis signal (diagnosed / stage / pathology / biopsy / s-p /
    # metastatic / resection / a year).
    priority_regex=(
        r"\A(?=.*(?:carcinoma|cancer|malignan|adenoca|neoplas|barret|(?-i:\bEAC\b)))"
        r"(?=.*(?:diagnos|stage\b|\bT[0-4]\b|patholog|biops|s/?p\b|status\s+post|metasta|"
        r"resect|(?:19|20)\d{2}|\d{1,3}\s*(?:years?|yrs?)\s+ago))"
    ),

    question=(""),

    snip_chars=300,          # stage / date usually sit a few lines from the cancer term
    max_snips_per_note=10,   # cap snippets from a single note
    snippet_budget=50,       # max snippets per input; above this we subsample -> distinct inputs
    char_budget=85000,       # hard safety cap on snippet chars per input
    n_recent=15,             # newest snippets: EAC is usually a late-in-history event
    n_distant=10,            # oldest snippets: catch an early Barrett's / original diagnosis
    priority_cap=25,         # at most this many priority anchors
    dedup="normalized",      # collapse copy-forward repeats differing only in short numbers
)

if __name__ == "__main__":
    run(CONFIG)
