#!/usr/bin/env python3
"""
route_crohns_montreal.py -- route Crohn's patients to the crohns_montreal task.

This step collects every patient ANY of the three IBD models called Crohn's and writes the
crohns_montreal inputs by FILTERING the existing ibd inputs down to those patients -- the same
note excerpts, paired with a focused Montreal-location prompt
(system_prompts/gemma4-thinking/crohns_montreal.txt). No notes are re-read; this is a routing
step, not an extraction.

The routed set is the UNION of Crohn's calls across all three sources:
  * the reviewer            (--reviewer-dir, ibd_rerun)
  * small model 1           (--path1, e.g. gemma4-26-A4-nonThinking)
  * small model 2           (--path2, e.g. qwen3.6-35-A3-nonThinking)
Deliberately recall-favoring: a patient one model calls Crohn's while another disagrees is still
Montreal-typed rather than dropped (the Montreal prompt can answer "not_documented" for any that
turn out not to be Crohn's). Pass all three dirs. consensus_reached rows in the reviewer out-dir
carry no diagnosis and contribute nothing -- correct, since under the escalate-all-IBD rule those
patients are all confident "no".

    ./route_crohns_montreal.py \
        --reviewer-dir /data/models/results/ibd_rerun/gemma4-31B-thinking/rep3 \
        --path1 /data/models/results/ibd/gemma4-26-A4-nonThinking/rep1 \
        --path2 /data/models/results/ibd/qwen3.6-35-A3-nonThinking/rep2 \
        --ibd-inputs /data/models/inputs/ibd --replicate 3 \
        --out-dir /data/models/inputs/crohns_montreal
"""
import argparse
import sys
from pathlib import Path

# read_answers (id -> latest answer, ID read from the RIGHT, NO_GRAMMAR handled) and parse
# (strip Gemma control tokens, keep the outermost {...}, json-load) are the ibd output-reading
# conventions. Reuse them so this reads the reviewer/small-model files exactly as the consensus
# step does, rather than re-deriving the same fragile parsing.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from skip_consensus_ibd import read_answers, parse, CROHNS  # noqa: E402


def _diagnosis(answer):
    """The 'diagnosis' field of one ibd answer, or None if it does not parse."""
    obj = parse(answer)
    return obj.get("diagnosis") if isinstance(obj, dict) else None


def crohns_ids(reviewer_dir, path1, path2):
    """Patient IDs ANY of the three IBD models called Crohn's -- the reviewer or either small
    model -- unioned. Recall-favoring on purpose: a patient the reviewer settled as non-Crohn's
    but a small model flagged as Crohn's is still routed, so borderline Crohn's get Montreal-typed
    rather than dropped (the Montreal prompt can answer "not_documented" for any that are not).
    consensus_reached rows carry no diagnosis, so they never contribute -- which is correct, since
    under the escalate-all-IBD rule those patients are all confident "no"."""
    crohns = set()
    per_source = []
    for name, d in (("reviewer", reviewer_dir), ("model1", path1), ("model2", path2)):
        if not d:
            per_source.append(f"{name}=skipped")
            continue
        ans, _, _ = read_answers(d)
        hits = {pid for pid, a in ans.items() if _diagnosis(a) == CROHNS}
        crohns |= hits
        per_source.append(f"{name}={len(hits):,}")
    print(f"[crohns_montreal] Crohn's by source: {', '.join(per_source)} | "
          f"union routed: {len(crohns):,}", file=sys.stderr)
    return crohns


def main():
    ap = argparse.ArgumentParser(description="Route Crohn's patients to the crohns_montreal task.")
    ap.add_argument("--reviewer-dir", required=True, help="ibd reviewer out-dir (output_*.txt)")
    ap.add_argument("--path1", help="ibd small-model 1 out-dir; a patient it calls Crohn's is routed")
    ap.add_argument("--path2", help="ibd small-model 2 out-dir; a patient it calls Crohn's is routed")
    ap.add_argument("--ibd-inputs", required=True, help="dir holding the ibd inputs_<r>.txt / IDs_<r>.txt")
    ap.add_argument("--replicate", type=int, default=1, help="which ibd input replicate to reuse (default 1)")
    ap.add_argument("--out-dir", required=True, help="crohns_montreal input dir to write")
    ap.add_argument("--dry-run", action="store_true", help="report the count, write nothing")
    args = ap.parse_args()

    ids = crohns_ids(args.reviewer_dir, args.path1, args.path2)
    if not ids:
        raise SystemExit("[crohns_montreal] no Crohn's patients found -- nothing to route")

    in_path = Path(args.ibd_inputs) / f"inputs_{args.replicate}.txt"
    id_path = Path(args.ibd_inputs) / f"IDs_{args.replicate}.txt"
    for p in (in_path, id_path):
        if not p.exists():
            raise SystemExit(f"[crohns_montreal] missing {p}")

    if args.dry_run:
        print(f"[crohns_montreal] dry run: would route {len(ids):,} Crohn's patients", file=sys.stderr)
        return

    outdir = Path(args.out_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    n_in = n_out = 0
    with in_path.open(encoding="utf-8") as fin, id_path.open(encoding="utf-8") as fid, \
         (outdir / "inputs_1.txt").open("w", encoding="utf-8") as fout, \
         (outdir / "IDs_1.txt").open("w", encoding="utf-8") as foid:
        for line, pid in zip(fin, fid):
            n_in += 1
            if pid.strip() in ids:
                fout.write(line if line.endswith("\n") else line + "\n")
                foid.write(pid if pid.endswith("\n") else pid + "\n")
                n_out += 1
    missing = len(ids) - n_out
    print(f"[crohns_montreal] filtered replicate {args.replicate}: {n_in:,} ibd inputs -> "
          f"{n_out:,} Crohn's inputs -> {outdir}"
          + (f" | WARNING: {missing:,} Crohn's IDs had no input line in replicate "
             f"{args.replicate}" if missing else ""), file=sys.stderr)


if __name__ == "__main__":
    main()
