#!/usr/bin/env python3
"""
skip_consensus_ibd.py -- pre-filter the reviewer job with the two small models' agreement.

ACTUAL CALL:
./skip_consensus_ibd.py --path1 /data/models/results/ibd/gemma4-26-A4-nonThinking/rep1 --path2 /data/models/results/ibd/qwen3.6-35-A3-nonThinking/rep2 --out-dir /data/models/results/ibd_rerun/gemma4-31B-thinking/rep3

Reads the output_*.txt files of a task's two jobs in specified path1 and path2 args and writes

    consensus_reached<TAB><ID>

into the reviewer (larger model) job's out-dir -- one line per ID the two models answered
effectively the same ("effectively the same" defined here). Because resume state is
just "which IDs already appear in output_*.txt", the reviewer job then skips those IDs and
reads only the disagreements. Run it BEFORE the reviewer job starts; re-running is safe (a
new stamp, IDs already marked stay marked).

An ID is left OUT (so the reviewer reads it) when either model errored, has not answered it
yet, answered something that does not parse as the ibd JSON, or when the two answers differ
meaningfully (again, "meaningfully" defined here).

WHAT COUNTS AS AGREEMENT lives in the AGREEMENT RULES block below -- it is the only part
meant to be edited, and it is IBD-specific (each task gets its own skip_consensus_<task>.py).
As set now: both answers must parse and `ibd` must match exactly, with "uncertain" going to the
reviewer regardless -- even two "uncertain"s, since neither model settled the question. When
both say "yes", `diagnosis` and the diagnosis YEAR must match exactly; when both say
"crohns_disease", `montreal_location` must match exactly AND be documented -- two
"not_documented" locations go to the reviewer, like two "uncertain" verdicts. Both models must
also be at least MIN_CONFIDENCE confident. `endoscopy_confirmed` and `psc` must agree on presence:
"yes" settles only against another "yes", while "no" and "not_documented" both count as no
evidence and agree with each other -- so a documented finding against an undocumented one
escalates. Everything else -- date_approximate,
colon_extent, perianal, care_setting, and the non-IBD `diagnosis` on a "no"/"uncertain" answer
-- is ignored; uncomment a line in the rule lists to make it count.

A non-answer never forms consensus, not even against the same non-answer: "uncertain" ibd,
"unknown" diagnosis_date and "not_documented" montreal_location all go to the reviewer. Note
the prompt puts approximate dates in date_approximate, so an "unknown" diagnosis_date is common
-- expect a fair number of dated-by-decade patients to land on the reviewer.

    ./skip_consensus_ibd.py --path1 <PATH> --path2 <PATH> --out-dir <PATH>
    ./skip_consensus_ibd.py --path1 <PATH> --path2 <PATH> --out-dir <PATH> --dry-run --examples 10
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
# "The models did not settle it" values, per field. A rule wrapped in settled() fails when
# EITHER model gives one of these -- two identical non-answers are not a consensus. All three
# are wired in below; empty a set (e.g. UNSETTLED_DATE = set()) to let its non-answers agree.
UNSETTLED_IBD  = {"uncertain"}                            # ibd:               "yes" | "no" | "uncertain"
UNSETTLED_DATE = {"unknown"}                              # diagnosis_date
UNSETTLED_LOC  = {"not_documented", "not_applicable"}     # montreal_location

# Values that mean "the note did not say", for fields where that should NOT block agreement.
# Only used by a rule wrapped in lenient() -- none are by default.
WILDCARDS = {"not_documented", "unknown", "not_applicable"}

CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2, "certain": 3}
# Set to "medium"/"high"/etc. to ALSO require both models be at least that confident before an
# ID can be skipped; None = confidence does not affect agreement.
MIN_CONFIDENCE = "medium"


def exact(a, b):
    return a == b


def same_year(a, b):
    """Dates are "YYYY", "YYYY-MM" or "YYYY-MM-DD" (or "unknown") -- compare the year only."""
    return a[:4] == b[:4]


def settled(cmp, unsettled):
    """Wrap a comparator so a non-answer on either side never forms consensus, even against the
    same non-answer: two models that both failed to pin the value have not settled it."""
    def _cmp(a, b):
        return a not in unsettled and b not in unsettled and cmp(a, b)
    return _cmp


def lenient(cmp, wildcards=WILDCARDS):
    """The opposite of settled(): a wildcard ("not documented") on either side never blocks
    agreement. Use for fields where one model simply being silent should not cost a skip."""
    def _cmp(a, b):
        return a in wildcards or b in wildcards or cmp(a, b)
    return _cmp


# For yes|no|not_documented findings (endoscopy_confirmed, psc): "no" and "not_documented" both
# mean "no evidence of this in these notes", so they agree with each other. "yes" is a positive
# finding and agrees only with "yes" -- one model documenting it while the other did not is a real
# conflict, not silence.
ABSENT = {"no", "not_documented"}


def same_presence(a, b):
    """yes/yes agrees; no, not_documented agree with each other; yes against either escalates."""
    return (a == b == "yes") or (a in ABSENT and b in ABSENT)


# Fields both answers must agree on, whatever the verdict. ("no"/"uncertain" bodies carry only
# ibd + diagnosis + confidence, so only those three can go here.) The verdict must match
# EXACTLY, and "uncertain" goes to the reviewer regardless -- even two "uncertain"s.
AGREE_ALWAYS = [
    ("ibd", settled(exact, UNSETTLED_IBD)),
    # ("diagnosis",  exact),   # NOTE: on a "no"/"uncertain" answer this is the NON-IBD diagnosis
]

# Additional fields to agree on when BOTH models said ibd="yes". Anything left out is ignored;
# a field a rule asks about but that is missing counts as a disagreement.
AGREE_IF_YES = [
    ("diagnosis", exact),
    # Year only, and an "unknown" date never forms consensus even against another "unknown" --
    # the prompt sends approximate dates to date_approximate, so those land on the reviewer.
    ("diagnosis_date", settled(same_year, UNSETTLED_DATE)),
    # Presence findings: only yes/yes settles a positive; "no" and "not_documented" agree.
    ("endoscopy_confirmed", same_presence),
    ("psc", same_presence),
    # ("colon_extent",        lenient(exact)),
    # ("care_setting",        lenient(exact)),
]

# Additional fields to agree on when both said diagnosis="crohns_disease" (montreal_location is
# Crohn's-only -- UC/IBDU answers carry "not_applicable" there).
AGREE_IF_CROHNS = [
    # An undocumented location never forms consensus, not even against another "not_documented":
    # neither model located the disease. ("not_applicable" here contradicts a Crohn's diagnosis,
    # so it goes to the reviewer too.)
    ("montreal_location", settled(exact, UNSETTLED_LOC)),
    # ("perianal", lenient(exact)),
]
CROHNS = "crohns_disease"
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
# keep only the outermost {...} before parsing.
_CONTROL = re.compile(r"<\|[^<>]*>|<[^<>]*\|>")


def parse(answer):
    """The single-level JSON object the ibd grammar produces, or None if it does not parse
    (a NO_GRAMMAR free-text answer, or a truncated one). Newlines come back escaped."""
    text = _CONTROL.sub(" ", answer.replace("\\n", "\n"))
    i, j = text.find("{"), text.rfind("}")
    if i < 0 or j < i:
        return None
    try:
        obj = json.loads(text[i:j + 1])
    except ValueError:
        return None
    return obj if isinstance(obj, dict) else None


def check(rules, ja, jb):
    """Apply one rule list; return the field that broke it, or None if they all pass. A field a
    rule asks about but that is absent is a disagreement, not a pass: the grammar always emits
    these, so a missing one means an ungrammatical (NO_GRAMMAR) answer."""
    for field, cmp in rules:
        if field not in ja or field not in jb:
            return f"missing {field}"
        if not cmp(ja[field], jb[field]):
            return field
    return None


def agrees(a, b):
    """Apply the AGREEMENT RULES to two raw answers. Returns (True, "") or (False, <reason>),
    where the reason is the field that broke it -- reasons are tallied in the summary so the
    rules can be tuned against real disagreements."""
    ja, jb = parse(a), parse(b)
    if ja is None or jb is None:
        return False, "unparseable"

    why = check(AGREE_ALWAYS, ja, jb)
    if why:
        return False, why

    if ja.get("ibd") == "yes" and jb.get("ibd") == "yes":
        why = check(AGREE_IF_YES, ja, jb)
        if why:
            return False, why
        if ja.get("diagnosis") == CROHNS and jb.get("diagnosis") == CROHNS:
            why = check(AGREE_IF_CROHNS, ja, jb)
            if why:
                return False, why

    if MIN_CONFIDENCE is not None:
        floor = CONFIDENCE_RANK[MIN_CONFIDENCE]
        if min(CONFIDENCE_RANK.get(j.get("confidence"), -1) for j in (ja, jb)) < floor:
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
