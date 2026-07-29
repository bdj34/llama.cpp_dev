#!/usr/bin/env python3
"""
skip_consensus_colectomy.py -- pre-filter the reviewer job with the two small models' agreement.

ACTUAL CALL:
./skip_consensus_colectomy.py --path1 /data/models/results/colectomy/gemma4-26-A4-nonThinking/rep1 --path2 /data/models/results/colectomy/qwen3.6-35-A3-nonThinking/rep2 --out-dir /data/models/results/colectomy_rerun/gemma4-31B-thinking/rep3

Reads the output_*.txt files of a task's two jobs in specified path1 and path2 args and writes

    consensus_reached<TAB><ID>

into the reviewer (larger model) job's out-dir -- one line per ID the two models answered
effectively the same ("effectively the same" defined here). Because resume state is
just "which IDs already appear in output_*.txt", the reviewer job then skips those IDs and
reads only the disagreements. Run it BEFORE the reviewer job starts; re-running is safe (a
new stamp, IDs already marked stay marked).

Like colonoscopy_timing (and unlike crc/ibd) this task's answer is a JSON ARRAY -- one object
per resection, since a patient can have a staged operation -- so agreement is about the SET of
operations, not one verdict.

WHAT COUNTS AS AGREEMENT lives in the AGREEMENT RULES block below -- it is the only part meant
to be edited, and it is task-specific (each task gets its own skip_consensus_<task>.py).
As set now: both answers must parse, report the same NUMBER of operations, and each paired
operation must share its date, its `procedure`, and the `segments` removed. Dates match at
whatever precision BOTH models gave -- two "YYYY-MM" dates on the month, two year-only dates on
the year -- but never across precisions ("2016-03" vs "2016" goes to the reviewer), and a date
that reached only date_approximate ("unknown") never matches. Segments compare as a set, so
order is irrelevant and a list naming every colonic segment equals "entire_colon". Two empty
arrays (both models found no resection) agree. date_approximate, care_setting and confidence are
ignored -- uncomment a line in AGREE_PER_ENTRY to make one count.

    ./skip_consensus_colectomy.py --path1 <PATH> --path2 <PATH> --out-dir <PATH>
    ./skip_consensus_colectomy.py --path1 <PATH> --path2 <PATH> --out-dir <PATH> --dry-run --examples 10
"""
import argparse
import json
import re
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

PROG = Path(__file__).name

# ============================ AGREEMENT RULES (EDIT HERE) ============================
# Which key holds the entry's date. Dates are compared at the finest precision the notes gave,
# and both models must have given the SAME precision (the colonoscopy_timing rule): two
# "YYYY-MM" dates match on the month, two year-only dates match on the year, but "2016-03"
# against "2016" does not -- one model placed the month and the other did not, so the reviewer
# settles it. A date only in date_approximate ("unknown") carries no year and never matches.
DATE_FIELD = "surgery_date"
_DATE_RE = re.compile(r"^\d{4}(-\d{2})?")

# Two empty arrays = both models say these excerpts document no resection that was performed.
# That is a real agreement; set to False to send those to the reviewer as well.
EMPTY_AGREES = True

CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2, "certain": 3}
# Set to "medium"/"high"/etc. to ALSO require EVERY entry of both answers be at least that
# confident before an ID can be skipped; None = confidence does not affect agreement.
MIN_CONFIDENCE = None


def exact(a, b):
    return a == b


# The colonic segments "entire_colon" stands for. A model that lists them has described the same
# resection as a model that wrote "entire_colon", so normalize before comparing. The flexures are
# left out of what a whole colon REQUIRES -- notes routinely walk cecum to sigmoid without naming
# them -- but they are still absorbed when a model does list them. Add them back to
# ENTIRE_COLON_REQUIRES to demand the full seven.
COLON_SEGMENTS = {"cecum", "ascending_colon", "hepatic_flexure", "transverse_colon",
                  "splenic_flexure", "descending_colon", "sigmoid_colon"}
ENTIRE_COLON_REQUIRES = COLON_SEGMENTS - {"hepatic_flexure", "splenic_flexure"}


def normalize_segments(values):
    """Segments as a set, with a complete colon collapsed to "entire_colon". Anything outside the
    colon proper (rectum, terminal_ileum) is kept, so a proctocolectomy still differs from a
    total colectomy."""
    s = {str(v) for v in values}
    if ENTIRE_COLON_REQUIRES <= s:
        s = (s - COLON_SEGMENTS) | {"entire_colon"}
    return sorted(s)


def same_segments(a, b):
    """segments is a JSON array and the grammar fixes no order, so compare it as a set:
    ["rectum", "sigmoid_colon"] and ["sigmoid_colon", "rectum"] are the same resection, and so
    are ["entire_colon"] and a list naming every colonic segment."""
    if not isinstance(a, list) or not isinstance(b, list):
        return False
    return normalize_segments(a) == normalize_segments(b)


# Per-entry rules, applied to the two models' operations paired up by date.
AGREE_PER_ENTRY = [
    ("procedure", exact),
    ("segments", same_segments),
    # ("care_setting", exact),
]
# ========================== END AGREEMENT RULES ==========================


def die(msg):
    sys.exit(f"{PROG}: error: {msg}")


def read_answers(out_dir):
    """id -> answer over every output_*.txt in out_dir (stamped names sort chronologically,
    so a later file wins). The ID is read from the RIGHT -- last tab field, or the one before
    a NO_GRAMMAR sentinel -- exactly as run_one.sh does, since the ID never contains a tab.
    Returns (answers, errors, no_grammar); a success always beats an Error for the same ID."""
    answers, errors, no_grammar = {}, set(), set()
    for path in sorted(Path(out_dir).glob("output_*.txt")):
        with path.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                f = line.rstrip("\n").split("\t")
                lenient_row = f[-1] == "NO_GRAMMAR"
                idx = len(f) - 2 if lenient_row else len(f) - 1
                if idx < 1:
                    continue
                pid, answer = f[idx], "\t".join(f[:idx]).strip()
                if answer == "Error":
                    if pid not in answers:
                        errors.add(pid)
                    continue
                answers[pid] = answer
                errors.discard(pid)
                if lenient_row:
                    no_grammar.add(pid)
                else:
                    no_grammar.discard(pid)
    return answers, errors, no_grammar


# The output file holds the model's raw text, which carries Gemma control tokens around the
# answer (the end-of-turn marker, and a thought channel on a thinking model). Strip them and
# keep only the outermost [...] before parsing.
_CONTROL = re.compile(r"<\|[^<>]*>|<[^<>]*\|>")


def parse(answer):
    """The JSON array the colectomy grammar produces, or None if it does not parse
    (a NO_GRAMMAR free-text answer, or a truncated one). Newlines come back escaped."""
    text = _CONTROL.sub(" ", answer.replace("\\n", "\n"))
    i, j = text.find("["), text.rfind("]")
    if i < 0 or j < i:
        return None
    try:
        obj = json.loads(text[i:j + 1])
    except ValueError:
        return None
    return obj if isinstance(obj, list) else None


def date_key(value):
    """The comparable part of an entry's date, or None if it carries no year at all.
    "YYYY-MM-DD" and "YYYY-MM" both key on "YYYY-MM" (the day is never compared); a year-only
    date keys on "YYYY". Keys are compared as-is, so a month-precision date and a year-only one
    never match. A decade ("1990s") and "unknown" key on None and never match."""
    if not isinstance(value, str) or value.endswith("s"):    # "1990s" is a decade, not a year
        return None
    m = _DATE_RE.match(value)
    return m.group(0) if m else None


def sorted_entries(entries):
    """(key, entry) pairs sorted by date key, or None if any entry cannot be keyed."""
    out = []
    for e in entries:
        if not isinstance(e, dict):
            return None
        k = date_key(e.get(DATE_FIELD))
        if k is None:
            return None
        out.append((k, e))
    return sorted(out, key=lambda p: p[0])


def agrees(a, b):
    """Apply the AGREEMENT RULES to two raw answers. Returns (True, "") or (False, <reason>),
    where the reason is what broke it -- reasons are tallied in the summary so the rules can be
    tuned against real disagreements."""
    ja, jb = parse(a), parse(b)
    if ja is None or jb is None:
        return False, "unparseable"
    if not ja and not jb:
        return (True, "") if EMPTY_AGREES else (False, "both empty")
    if len(ja) != len(jb):
        return False, "count"

    ea, eb = sorted_entries(ja), sorted_entries(jb)
    if ea is None or eb is None:
        return False, "date unknown"
    ka, kb = [k for k, _ in ea], [k for k, _ in eb]
    if ka != kb:
        # Same years but different keys means one model placed the month and the other did not.
        return False, "date precision" if [k[:4] for k in ka] == [k[:4] for k in kb] else "date"

    for (_, x), (_, y) in zip(ea, eb):
        for field, cmp in AGREE_PER_ENTRY:
            if field not in x or field not in y:
                return False, f"missing {field}"
            if not cmp(x[field], y[field]):
                return False, field

    if MIN_CONFIDENCE is not None:
        floor = CONFIDENCE_RANK[MIN_CONFIDENCE]
        for e in ja + jb:
            if CONFIDENCE_RANK.get(e.get("confidence"), -1) < floor:
                return False, "confidence"

    return True, ""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--path1", required=True, help="required: path to the out-dir from the first model")
    ap.add_argument("--path2", required=True, help="required: path to the out-dir from the second model")
    ap.add_argument("--out-dir", required=True, help="required: path to the out-dir of the reviewer model")
    ap.add_argument("--allow-no-grammar", action=argparse.BooleanOptionalAction, default=True,
                    help="let NO_GRAMMAR (grammar-free retry) answers count toward consensus (default: on; "
                         "they still have to parse and pass the rules). --no-allow-no-grammar drops them.")
    ap.add_argument("--examples", type=int, default=0, metavar="N",
                    help="print N sample disagreeing answer pairs (to tune the rules)")
    ap.add_argument("--dry-run", action="store_true", help="report the counts, write nothing")
    args = ap.parse_args()

    src_dirs = [Path(args.path1), Path(args.path2)]
    for d in src_dirs:
        if not d.is_dir():
            die(f"no results dir: {d}")
    out_dir = Path(args.out_dir)
    if out_dir.resolve() in {d.resolve() for d in src_dirs}:
        die(f"--out-dir is one of the source model dirs ({out_dir}); that would mark its own IDs done")

    (ans_a, err_a, ng_a), (ans_b, err_b, ng_b) = [read_answers(d) for d in src_dirs]
    if not args.allow_no_grammar:
        for answers, ng in ((ans_a, ng_a), (ans_b, ng_b)):
            for pid in ng:
                answers.pop(pid, None)

    both = sorted(set(ans_a) & set(ans_b))
    agreed, reasons, examples = [], Counter(), []
    for pid in both:
        ok, why = agrees(ans_a[pid], ans_b[pid])
        if ok:
            agreed.append(pid)
        else:
            reasons[why] += 1
            if len(examples) < args.examples:
                examples.append((pid, why, ans_a[pid], ans_b[pid]))

    n_disagreed = len(both) - len(agreed)
    # Everything either model has touched; whatever is not agreed falls to the reviewer -- as do
    # any IDs neither model reached, which are simply absent from the outputs counted here.
    n_left = len(set(ans_a) | set(ans_b) | err_a | err_b) - len(agreed)

    for d, answers, errs, ng in zip(src_dirs, (ans_a, ans_b), (err_a, err_b), (ng_a, ng_b)):
        print(f"{d}: {len(answers)} answers, {len(errs)} errors, {len(ng)} NO_GRAMMAR"
              f"{'' if args.allow_no_grammar else ' (excluded)'}", file=sys.stderr)
    print(f"both answered: {len(both)}  agreed: {len(agreed)}  disagreed: {n_disagreed}", file=sys.stderr)
    if reasons:
        print("  disagreed on: " + ", ".join(f"{k}={v}" for k, v in reasons.most_common()), file=sys.stderr)
    print(f"for the reviewer: {n_left} IDs ({n_disagreed} disagreed, "
          f"{n_left - n_disagreed} not answered by both)", file=sys.stderr)
    for pid, why, a, b in examples:
        print(f"\n[{pid}] differs on {why}\n  1: {a}\n  2: {b}", file=sys.stderr)

    if args.dry_run:
        print("dry run: nothing written", file=sys.stderr)
        return
    if not agreed:
        die("no IDs agreed -- nothing written")

    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"output_consensus_{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.txt"
    if out_path.exists():
        die(f"{out_path} already exists")
    with out_path.open("w", encoding="utf-8") as fh:
        for pid in agreed:
            fh.write(f"consensus_reached\t{pid}\n")
    print(f"wrote {len(agreed)} consensus_reached rows -> {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
