#!/usr/bin/env python3
"""
extract_barretts_eac.py -- inputs for the `barretts_eac` task: identify Barrett's esophagus
(BE) and esophageal adenocarcinoma (EAC) from a patient's EGD reports + esophageal pathology.

Aligned to the be_egd system prompt (system_prompts/gemma4/be_egd.txt): the model is asked to
distinguish pathology-confirmed BE (intestinal metaplasia on esophageal biopsy) from
endoscopic suspicion only (salmon-colored mucosa, a Prague C&M grade), to report the highest
dysplasia grade, and to ascertain EAC with a year. NOTE: that prompt was written for an
EGD-CPT index encounter with a +/- 30-day note window; the v2 buckets carry no procedure index
dates, so this runs patient-level (like extract_crc.py) -- an EGD-CPT-windowed variant would
need the index dates, same dependency that parks colonoscopy_report.

Domain care: "intestinal metaplasia" is Barrett's ONLY in the esophagus -- gastric intestinal
metaplasia is a different entity and a common false positive -- so that term is gated to
esophageal context (esophagus / GE junction / Z-line / distal esophagus / salmon mucosa).
Named "Barrett's" is unambiguously esophageal and needs no gate. As with CRC there is no
ignore_regex: recall-first for these outcomes, and "no Barrett's" / negation is left to the
model (it must see the negatives to answer "no").

    ./extract_barretts_eac.py --buckets /data/note_buckets --out-dir /data/barretts_eac/raw_inputs
"""
from snippet_lib import TaskConfig, run

# Esophageal context used to gate the ambiguous "intestinal metaplasia" term.
ESO = (
    r"(?:esophag\w*|distal\s+esoph\w*|gastro[- ]?esophageal(?:\s+junction)?|"
    r"\bgej\b|\bge\s+junction|z[- ]?line|salmon[- ]?colored)"
)
# Unambiguously-esophageal Barrett's vocabulary.
BE_TERM = r"barrett\w*|columnar[- ]lined\s+esophag\w*|specialized\s+intestinal\s+metaplasia"
# Intestinal metaplasia, but only when esophageal context sits within ~40 chars either side.
IM_ESO = rf"{ESO}\W.{{0,40}}?intestinal\s+metaplasia|intestinal\s+metaplasia\W.{{0,40}}?{ESO}"
# Esophageal / GE-junction adenocarcinoma (EAC) vocabulary.
EAC_TERM = (
    r"esophag\w*\s+adenocarcinoma|adenocarcinoma\s+of\s+(?:the\s+)?(?:distal\s+)?esophag\w*|"
    r"adenocarcinoma\s+(?:at|of|involving|near)\s+(?:the\s+)?"
    r"(?:gej|ge\s+junction|gastro[- ]?esophageal\s+junction)|"
    r"\beac\b|esophageal\s+(?:cancer|carcinoma)|esophageal\s+ca\b"
)

CONCEPT = (
    rf"{BE_TERM}|{IM_ESO}|{EAC_TERM}|"
    r"\bc\d{1,2}\s*m\d{1,2}\b|"                       # Prague C&M grade, e.g. "C2M4"
    r"salmon[- ]?colored(?:\s+mucosa)?|tongues?\s+of\s+salmon"   # endoscopic BE appearance
)

CONFIG = TaskConfig(
    name="barretts_eac",

    # WHICH notes/snippets to pull: named Barrett's, esophageal-gated intestinal metaplasia,
    # EAC vocabulary, a Prague grade, or the salmon-mucosa endoscopic appearance. (No ignore
    # regex -- screening/negation left to the model; see the module docstring.)
    concept_regex=rf"(?i)(?:{CONCEPT})",

    # WHICH snippets are "decisive" and must appear in every one of the 3 inputs. Five branches:
    #  A) named Barrett's + a confirming/grading/dating detail (biopsy, dysplasia, Prague, year),
    #  B) esophageal intestinal metaplasia confirmed on biopsy (pathology-proven BE, even if the
    #     word "Barrett's" is absent),
    #  C) any EAC mention (a cancer is decisive on its own),
    #  D) a Prague C&M grade (documents endoscopic Barrett's extent),
    #  E) salmon-colored mucosa in esophageal context (the endoscopic-suspicion-only BE finding).
    priority_regex=(
        r"(?is)(?:"
        r"(?=.*(?:barrett|columnar[- ]lined\s+esophag|specialized\s+intestinal\s+metaplasia))"
        r"(?=.*(?:biops|patholog|goblet|dysplasia|indefinite|prague|c\d{1,2}\s*m\d{1,2}|"
        r"salmon|(?:19|20)\d{2}))"
        r"|"
        r"(?=.*intestinal\s+metaplasia)(?=.*(?:esophag|distal\s+esoph|\bgej\b|ge\s+junction|"
        r"z[- ]?line))(?=.*(?:biops|patholog|goblet))"
        r"|"
        r"(?=.*(?:esophag\w*\s+adenocarcinoma|adenocarcinoma\s+of\s+(?:the\s+)?(?:distal\s+)?esophag|"
        r"adenocarcinoma\s+.{0,25}(?:gej|ge\s+junction|gastro[- ]?esophageal\s+junction)|"
        r"\beac\b|esophageal\s+(?:cancer|carcinoma)))"
        r"|"
        r"(?=.*\bc\d{1,2}\s*m\d{1,2}\b)"
        r"|"
        r"(?=.*salmon[- ]?colored)(?=.*(?:esophag|distal\s+esoph|\bgej\b|ge\s+junction|z[- ]?line))"
        r")"
    ),

    # Instruction appended once at the END of every input, after the snippets.
    question=(
        "Question: Using only these notes, determine (1) whether this patient has Barrett's "
        "esophagus -- and if so whether it is pathology-confirmed (intestinal metaplasia on "
        "esophageal biopsy) or endoscopic suspicion only, its segment length / Prague grade if "
        "stated, and the highest dysplasia grade (none / indefinite / low-grade / high-grade); "
        "and (2) whether the patient has esophageal adenocarcinoma (EAC), and if so the year of "
        "diagnosis. Base findings on the EGD and any linked esophageal pathology."
    ),

    snip_chars=380,          # esophageal pathology detail often sits a few lines from the term
    max_snips_per_note=10,   # cap snippets from a single note
    snippet_budget=45,       # max snippets per input; above this we subsample -> 3 distinct inputs
    char_budget=65000,       # hard safety cap on snippet chars per input
    n_recent=8,              # newest snippets always kept (current surveillance / new EAC)
    n_distant=8,             # oldest snippets always kept (original BE diagnosis may be old)
    priority_cap=25,         # at most this many priority anchors
    dedup="normalized",      # collapse copy-forward repeats differing only in short numbers; keep years
)

if __name__ == "__main__":
    run(CONFIG)
