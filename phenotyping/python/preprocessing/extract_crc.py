#!/usr/bin/env python3
"""
extract_crc.py -- inputs for the `crc` task (colorectal-cancer ascertainment).

CRC is rare, so a MISSED true positive is the costly error. We deliberately do NOT use
an ignore_regex here: dropping whole SNIPPETS that mention screening / surveillance /
family history risks discarding a real diagnosis that happens to share a window with
that context. Screening boilerplate is instead excluded at the PHRASE level (see
concept_regex below), which cannot lose a window containing affirmative language.
NOTE: patients whose notes contain ONLY screening boilerplate now produce zero
snippets and land in audit_no_snippets.txt -- downstream must count them as "No",
they no longer flow to the model. Instead:

  * concept_regex captures affirmative cancer vocabulary (colon/colonic/rectal/rectum/
    rectosigmoid/colorectal/sigmoid/cecal + carcinoma/adenocarcinoma/adenoca/cancer/
    malignant/neoplasm, allowing a short gap so "cecal mass adenocarcinoma" hits; "colon
    ca" shorthand; reverse "cancer of the colon"; CRC). The single precision guard:
    "<cancer term> screening"
    ("colorectal cancer screening", "CRC screening") is excluded at the phrase level,
    so reminder boilerplate alone never pulls a snippet, while "colon cancer found on
    screening colonoscopy" still does. The reverse order ("screening for colon cancer")
    is deliberately let through -- rarer, and recall beats precision here.
  * priority_regex anchors snippets that state a real diagnosis into all three inputs.
  * the MODEL distinguishes "diagnosed with colon cancer" from "screening for colon
    cancer" / "family history of colon cancer" -- that judgement is left to the LLM, which
    is far more reliable at it than a regex, and never costs us a dropped positive.

    ./extract_crc.py --buckets /data/note_buckets --out-dir /data/crc/raw_inputs
"""
from snippet_lib import TaskConfig, run

# SITE covers the adjectival/segment forms too: colon/colonic, rect* (rectal/rectum/
# rectosigmoid), sigmoid, cecal/cecum.
SITE  = r"\b(?:colorectal|colon(?:ic)?|rect\w*|sigmoid|cec(?:al|um))"
MALIG = r"(?:adenoca\w*|(?:adeno)?carcinoma|cancer|malignan\w*|neoplas)"
# The one precision guard: a cancer term immediately followed by "screen..." is reminder
# boilerplate ("colorectal cancer screening: due", "CRC screening"), not a diagnosis.
# Applied at the PHRASE level, so a real mention elsewhere in the window still triggers.
# Everything else matches -- err on recall, the model judges context.
NOT_SCREENING = r"(?!\s+screen)"
CANCER = (
    rf"{SITE}.{{0,20}}?{MALIG}{NOT_SCREENING}|"  # "colon cancer", "colonic adenoca", "cecal mass carcinoma"
    rf"{SITE}\s+ca\b{NOT_SCREENING}|"            # "colon ca" shorthand
    rf"{MALIG}\s+of\s+(?:the\s+)?{SITE}|"        # "adenocarcinoma of the colon"
    rf"\bca\s+of\s+(?:the\s+)?{SITE}|"           # "Ca of the sigmoid"
    rf"\bcrc\b{NOT_SCREENING}"                   # "CRC", but not "CRC screening"
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
        r"\A(?=.*(?:carcinoma|cancer(?!\s+screen)|malignan|adenoca|\bcrc\b(?!\s+screen)|neoplas))"
        r"(?=.*(?:diagnos|stage\b|s/?p\b|status\s+post|patholog|biops|"
        r"positive\s+for|metastatic|resect|(?:19|20)\d{2}))"
    ),

    # Instruction appended once at the END of every input, after the snippets.
    question=(""
        # "Question: Using only these notes, determine whether this patient was actually "
        # "DIAGNOSED with colorectal cancer (not merely screened, at risk, or with a family "
        # "history), and if so the year and month of diagnosis."
    ),

    snip_chars=300,          # slightly wider context than IBD -- CRC dates/stage often sit a few lines away
    max_snips_per_note=10,   # cap snippets from a single note
    snippet_budget=50,       # max snippets per input; above this we subsample -> 3 distinct inputs
    char_budget=85000,       # hard safety cap on snippet chars per input
    n_recent=15,             # newest snippets always kept (CRC is usually a late-in-history event)
    n_distant=10,            # oldest snippets always kept (catch an early/original diagnosis)
    priority_cap=25,         # at most this many priority anchors
    dedup="normalized",      # collapse copy-forward repeats differing only in short numbers; keep years
)

if __name__ == "__main__":
    run(CONFIG)
