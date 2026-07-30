#!/usr/bin/env python3
"""
skip_consensus_crc.py -- pre-filter the reviewer job with the two small models' agreement.

ACTUAL CALL:
./skip_consensus_crc.py --path1 /data/models/results/crc_free_text/gemma4-26-A4-nonThinking/rep1 --path2 /data/models/results/crc_free_text/qwen3.6-35-A3-nonThinking/rep2 --out-dir /data/models/results/crc_free_text_rerun/gemma4-31B-thinking/rep3

Reads the output_*.txt files of a task's two jobs in specified path1 and path2 args and writes

    consensus_reached<TAB><ID>

into the reviewer (larger model) job's out-dir -- one line per ID the two models answered
effectively the same ("effectively the same" defined here). Because resume state is
just "which IDs already appear in output_*.txt", the reviewer job then skips those IDs and
reads only the disagreements. Run it BEFORE the reviewer job starts; re-running is safe (a
new stamp, IDs already marked stay marked).

An ID is left OUT (so the reviewer reads it) when either model errored, has not answered it
yet, answered something that does not parse as the crc_free_text JSON, or when the two answers
differ meaningfully (again, "meaningfully" defined here).

WHAT COUNTS AS AGREEMENT lives in the AGREEMENT RULES block below -- it is the only part
meant to be edited, and it is CRC-specific (each task gets its own skip_consensus_<task>.py).
As set now the reviewer sees every patient EXCEPT those both models confidently called
negative: an ID is skipped only when both answers parse, both say `crc` = "no", and both are at
least MIN_CONFIDENCE confident. Any positive from either model escalates -- the validated
pipeline's either-positive rule, so a CRC diagnosis is never confirmed on two votes alone.

That makes the AGREE_IF_YES rules inert; they are kept because restoring ("crc", exact) in
AGREE_ALWAYS brings them straight back for double-positive answers.

    ./skip_consensus_crc.py --path1 <PATH> --path2 <PATH> --out-dir <PATH>
    ./skip_consensus_crc.py --path1 <PATH> --path2 <PATH> --out-dir <PATH> --dry-run --examples 10
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
# Values that mean "the note did not say", on EITHER side, so they cannot contradict a real
# answer. A rule wrapped in lenient() passes when either model gives one of these -- no rule
# below is, so a non-answer currently compares like any other value.
WILDCARDS = {"unknown", "not_documented"}
SITE_WILDCARDS = WILDCARDS | {"colon_nos"}          # "colon, not otherwise specified"

# Anatomical sites collapsed to the granularity we actually care about, for same_site_group.
# NOT wired in: anatomical_site compares exactly below, so sigmoid vs descending disagree.
# Swap in same_site_group (or lenient(same_site_group, SITE_WILDCARDS)) to use the grouping.
SITE_GROUP = {
    "cecum": "right", "ascending_colon": "right", "hepatic_flexure": "right", "right_colon": "right",
    "transverse_colon": "transverse",
    "splenic_flexure": "left", "descending_colon": "left", "sigmoid_colon": "left", "left_colon": "left",
    "rectosigmoid": "rectal", "rectum": "rectal",   # rectosigmoid grouped with rectum, not left
}

CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2, "certain": 3}
# Both models must be at least this confident before an ID can be skipped. With every positive
# escalated above, this now governs the NEGATIVES: a hesitant "no" goes to the reviewer, which is
# the direction that protects recall on a rare cancer. None = confidence does not affect agreement.
MIN_CONFIDENCE = "high"


def exact(a, b):
    return a == b

# def exact_and_known(a, b):
#     return a != "unknown" and b != "unknown" and a != "not_documented" and b != "not_documented" and a == b


def same_known_year(a, b):
    """Dates are "YYYY", "YYYY-MM" or "YYYY-MM-DD" (or "unknown") -- compare the year only.
    "unknown" never agrees, not even with another "unknown": two models that both failed to
    date the diagnosis have not settled it, so the reviewer gets those."""
    return a != "unknown" and b != "unknown" and a[:4] == b[:4]


def same_site_group(a, b):
    return SITE_GROUP.get(a, a) == SITE_GROUP.get(b, b)


def lenient(cmp, wildcards=WILDCARDS):
    """Wrap a comparator so a wildcard ("not documented") on either side never blocks agreement."""
    def _cmp(a, b):
        return a in wildcards or b in wildcards or cmp(a, b)
    return _cmp


def negative_agreement(a, b):
    """Only two "no" answers settle a patient. ANY positive goes to the reviewer, matching the
    validated pipeline's either-positive escalation -- a CRC call is never made on two votes.
    Use plain exact() here to let two agreeing positives be skipped again."""
    return a == b == "no"


# Values that escalate even when BOTH models give them, so the summary can report an agreed
# positive as policy rather than as a conflict between the models.
negative_agreement.policy_escalates = {"yes"}


# Fields both answers must agree on, whatever the verdict. (crc="no" bodies carry only
# crc + confidence, so only those two can go here.)
AGREE_ALWAYS = [
    ("crc", negative_agreement),
]

# Additional fields to agree on when BOTH models said crc="yes". These are INERT while
# AGREE_ALWAYS escalates every positive -- no answer reaches them. They apply again the moment
# ("crc", exact) is restored above. A field a rule asks about but that is missing counts as a
# disagreement.
AGREE_IF_YES = [
    ("diagnosis_date", same_known_year),
    ("anatomical_site", exact),
    ("stage_ajcc",     exact),
    ("detection_mode", exact),
    # ("care_setting",   lenient(exact)),
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
# keep only the outermost {...} before parsing.
_CONTROL = re.compile(r"<\|[^<>]*>|<[^<>]*\|>")


def parse(answer):
    """The single-level JSON object the crc_free_text grammar produces, or None if it does not
    parse (a NO_GRAMMAR free-text answer, or a truncated one). Newlines come back escaped."""
    text = _CONTROL.sub(" ", answer.replace("\\n", "\n"))
    i, j = text.find("{"), text.rfind("}")
    if i < 0 or j < i:
        return None
    try:
        obj = json.loads(text[i:j + 1])
    except ValueError:
        return None
    return obj if isinstance(obj, dict) else None


def agrees(a, b):
    """Apply the AGREEMENT RULES to two raw answers. Returns (True, "") or (False, <reason>),
    where the reason is the field that broke it -- reasons are tallied in the summary so the
    rules can be tuned against real disagreements."""
    ja, jb = parse(a), parse(b)
    if ja is None or jb is None:
        return False, "unparseable"

    # A field a rule asks about but that is absent is a disagreement, not a pass: the grammar
    # always emits these, so a missing one means an ungrammatical (NO_GRAMMAR) answer.
    for field, cmp in AGREE_ALWAYS:
        if field not in ja or field not in jb:
            return False, f"missing {field}"
        if not cmp(ja[field], jb[field]):
            # Both models saying "yes" is not a disagreement -- it is the either-positive rule
            # sending an agreed positive for review. Report it as such so the tally separates
            # policy escalations from genuine model conflicts.
            if ja[field] == jb[field] and ja[field] in getattr(cmp, "policy_escalates", ()):
                return False, f"{field} agreed positive"
            return False, field

    if ja.get("crc") == "yes" and jb.get("crc") == "yes":
        for field, cmp in AGREE_IF_YES:
            if field not in ja or field not in jb:
                return False, f"missing {field}"
            if not cmp(ja[field], jb[field]):
                return False, field

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
