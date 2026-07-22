#!/usr/bin/env python3
"""
extract_crc.py -- inputs for the `crc` task (colorectal-cancer ascertainment).

CRC is rare, so a MISSED true positive is the costly error. We deliberately do NOT use
an ignore_regex here: dropping snippets that mention screening / surveillance / family
history risks discarding a real diagnosis that happens to share a window with that
context, and it silently drops screening-only patients from the pipeline entirely (they
should be evaluated and returned as "No", not vanish). Instead:

  * concept_regex captures affirmative cancer vocabulary (colon/rectal/colorectal
    carcinoma/adenocarcinoma/cancer/malignant neoplasm, "colon ca" shorthand, reverse
    "cancer of the colon", CRC, metastatic colorectal cancer). It already excludes bare
    "screening" text (no cancer term -> no snippet).
  * priority_regex anchors snippets that state a real diagnosis into all three inputs.
  * the MODEL distinguishes "diagnosed with colon cancer" from "screening for colon
    cancer" / "family history of colon cancer" -- that judgement is left to the LLM, which
    is far more reliable at it than a regex, and never costs us a dropped positive.

    ./extract_crc.py --buckets /data/note_buckets --out-dir /data/crc/raw_inputs
"""
from snippet_lib import TaskConfig, run

SITE = r"(?:colon|colorectal|rect(?:al|um)|sigmoid|cecal|cecum)"
CANCER = (
    # SITE then malignancy: "colon cancer", "rectal adenocarcinoma", "sigmoid carcinoma".
    rf"{SITE}\s+(?:adeno)?(?:carcinoma|cancer|malignan\w*|neoplasm)|"
    # SITE + "ca" shorthand: "colon ca".
    rf"{SITE}\s+ca\b|"
    # malignancy then SITE (reverse word order): "adenocarcinoma of the colon",
    # "cancer of the rectum", "Ca of the sigmoid", "malignancy of the colon".
    rf"(?:adeno)?(?:carcinoma|cancer|malignan\w*|neoplasm|\bca\b)\s+of\s+(?:the\s+)?{SITE}|"
    # metastatic colorectal cancer; and the CRC abbreviation.
    r"metastatic\s+(?:colon|colorectal|rectal)\s+(?:cancer|carcinoma)|\bcrc\b"
)

CONFIG = TaskConfig(
    name="crc",

    # WHICH notes/snippets to pull: affirmative colorectal-cancer vocabulary only.
    # (No ignore_regex -- see the module docstring; screening context is left to the model.)
    concept_regex=rf"(?i)(?:{CANCER})",

    # WHICH snippets are "decisive" and must appear in every one of the 3 inputs: a cancer
    # term co-located with a real-diagnosis signal (diagnosed / stage / s-p / pathology /
    # biopsy / positive for / metastatic / resect / a year).
    priority_regex=(
        r"(?is)(?=.*(?:carcinoma|cancer|malignan|adenoca|\bcrc\b|neoplasm))"
        r"(?=.*(?:diagnos|stage\b|s/?p\b|status\s+post|patholog|biops|"
        r"positive\s+for|metastatic|resect|(?:19|20)\d{2}))"
    ),

    # Instruction appended once at the END of every input, after the snippets.
    question=(
        "Question: Using only these notes, determine whether this patient was actually "
        "DIAGNOSED with colorectal cancer (not merely screened, at risk, or with a family "
        "history), and if so the year and month of diagnosis."
    ),

    snip_chars=420,          # wider context than IBD -- CRC dates/stage often sit a few lines away
    max_snips_per_note=10,   # cap snippets from a single note
    snippet_budget=60,       # max snippets per input; above this we subsample -> 3 distinct inputs
    char_budget=85000,       # hard safety cap on snippet chars per input
    n_recent=15,             # newest snippets always kept (CRC is usually a late-in-history event)
    n_distant=10,            # oldest snippets always kept (catch an early/original diagnosis)
    priority_cap=28,         # at most this many priority anchors
    dedup="normalized",      # collapse copy-forward repeats differing only in short numbers; keep years
)

if __name__ == "__main__":
    run(CONFIG)
