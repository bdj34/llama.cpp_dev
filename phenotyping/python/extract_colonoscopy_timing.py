#!/usr/bin/env python3
"""
extract_colonoscopy_timing.py -- inputs for `colonoscopy_timing`.

Goal: reconstruct WHEN a patient had colonoscopies -- especially EXTERNAL (non-VA)
ones only mentioned in passing in GP/progress notes -- with date and site. Recall
matters, so the concept regex is deliberately broad (any colonoscopy mention); the
surrounding window carries the date and the VA/external cue for the model.

Two filters keep it clean without losing real events:
  * ignore_regex drops pure FUTURE/scheduling language ("due for", "recommend a
    screening colonoscopy", "refer for colonoscopy") -- these are not events ...
  * ... unless the snippet also carries a PAST-event cue (priority_regex: a 4-digit
    year, "had"/"last"/"ago"/"prior"/"status post"/"underwent"/"performed on"),
    which overrides the ignore so a genuine dated colonoscopy is never dropped.

Runs in "chunk" mode: every distinct colonoscopy mention must be seen (a subsample
could drop a date and undercount external procedures), so the patient's deduplicated
mentions are chunked and the SAME chunk set is written to all three replicate files.
Exact dedup is used (not normalized) so "colonoscopy 3 years ago" and "5 years ago"
stay distinct while byte-identical copy-forwards still collapse.

    ./extract_colonoscopy_timing.py --buckets /data/note_buckets \
        --out-dir /data/colonoscopy_timing/raw_inputs
"""
from snippet_lib import TaskConfig, run

CONFIG = TaskConfig(
    name="colonoscopy_timing",
    concept_regex=r"(?i)colonoscop\w*",
    # DROP snippets that are pure FUTURE/scheduling language (recommend / due for / plan
    # for / refer for a colonoscopy) -- these are not events -- UNLESS priority_regex fires.
    ignore_regex=(
        r"(?i)(?:recommend|schedul\w*|due\s+for|plan(?:ned|s|ning)?\s+for|"
        r"will\s+(?:need|schedule|get)|refer\w*\s+for|should\s+(?:have|get|undergo)|"
        r"advis\w*|order\w*\s+for).{0,10}?(?:screening\s+|surveillance\s+|repeat\s+)?colonoscop"
    ),

    # Overrides the ignore above: a colonoscopy mention carrying a PAST-event cue (a year,
    # had / last / ago / prior / status post / underwent / performed on) is a real event and
    # is kept. (In chunk mode this flag is used only to protect snippets from ignore_regex.)
    priority_regex=(
        r"\A(?=.*colonoscop)"
        r"(?=.*(?:(?:19|20)\d{2}|\bhad\b|\blast\b|\bago\b|\bprior\b|\bprevious\b|"
        r"status\s+post|s/?p\b|underwent|completed|performed\s+(?:on|at|in)))"
    ),

    # Instruction appended once at the END of every input, after the snippets.
    question=(""
        # "Question: List each distinct colonoscopy this patient underwent, with its year and "
        # "month if known, and whether it was performed at the VA or externally (non-VA)."
    ),

    snip_chars=200,            # narrow window: we want the date + VA/external cue near the mention
    max_snips_per_note=15,     # cap snippets from a single note
    dedup="exact",             # exact (not normalized): keep "3 years ago" vs "5 years ago" distinct,
                               # since those are different events; byte-identical copies still collapse
    mode="chunk",              # COMPLETENESS mode: every colonoscopy must be seen, so we do NOT
                               # subsample. Snippets are chunked and the SAME set goes to all 3 inputs.
    chunk_size=25,             # snippets per input line in chunk mode
)

if __name__ == "__main__":
    run(CONFIG)
