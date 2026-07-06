#!/usr/bin/env python3
"""
Consensus / post-processing for the phenotyping pipeline. Replaces the per-variable
reproduce_results/*/stepN_aggregate_*.R scripts with one pandas-based tool.

Reads the raw llama-data-extraction outputs for every (pass, model), parses each model's
answer with a task-specific parser, takes a per-field majority vote across models (with a
confidence tier by agreement level), merges passes on ID, and writes results.csv.

Output-line formats emitted by the (modified) tool:
    <response>\t<ID>                 normal, grammar-constrained
    <response>\t<ID>\tNO_GRAMMAR     grammar-free retry of a runaway input (parse leniently)
    Error\t<ID>                      hard failure (no usable answer)

Add a task's field parser to PARSERS below: parser(response, no_grammar) -> {field: value}.
"""
import argparse
import csv
import glob
import os
import re
import sys
from collections import Counter, defaultdict


# ---------------------------------------------------------------------------
# Task-specific parsers.  Each returns {field_name: value} from one model's raw answer.
# `no_grammar=True` means the answer was produced without the grammar (lenient parsing).
# Return {} if nothing parseable (counts as a non-vote / low confidence).
# ---------------------------------------------------------------------------
def parse_colectomy(resp, no_grammar=False):
    """Grammar: 'Answer: Yes.\\n' + repeated 'Procedure type: ... Procedure year: YYYY.'"""
    resp = resp.replace("\\n", "\n")
    out = {}
    m = re.search(r"Answer:\s*(Yes|No)", resp, re.IGNORECASE)
    if not m:
        return out
    out["colectomy"] = m.group(1).capitalize()
    if out["colectomy"] == "Yes":
        years = [int(y) for y in re.findall(r"Procedure year:\s*(\d{4})", resp)]
        if years:
            out["first_colectomy_year"] = min(years)
        tm = re.search(r"Procedure type:\s*([^.]+)\.", resp)
        if tm:
            out["procedure_type"] = tm.group(1).strip().lower()
    return out


PARSERS = {
    "colectomy": parse_colectomy,
    # crc, ibd, colonoscopy_timing, colonoscopy_report parsers added with their tasks.
}


# ---------------------------------------------------------------------------
# Output loading
# ---------------------------------------------------------------------------
def load_model_output(outdir):
    """Return {id: {'resp', 'error', 'no_grammar'}} for a model.

    Reads output_*.txt recursively so data-parallel ('dual') runs — whose two halves land in
    <outdir>/gpu0/ and <outdir>/gpu1/ — are both picked up. Within each directory the NEWEST
    output file is used (so re-runs don't double-count); rows are unioned across directories
    (each ID is produced by exactly one half).
    """
    files = glob.glob(os.path.join(outdir, "**", "output_*.txt"), recursive=True)
    if not files:
        sys.exit(f"aggregate: no output_*.txt under {outdir}")
    newest_per_dir = {}
    for fp in files:
        d = os.path.dirname(fp)
        if d not in newest_per_dir or os.path.basename(fp) > os.path.basename(newest_per_dir[d]):
            newest_per_dir[d] = fp
    recs = {}
    for fp in sorted(newest_per_dir.values()):
        with open(fp, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t")
                if len(parts) < 2:
                    continue
                resp, pid = parts[0], parts[1]
                no_grammar = len(parts) >= 3 and parts[2] == "NO_GRAMMAR"
                recs[pid] = {"resp": resp, "error": resp == "Error", "no_grammar": no_grammar}
    print(f"aggregate: loaded {len(recs)} rows from {len(newest_per_dir)} dir(s) under {outdir}", file=sys.stderr)
    return recs


# ---------------------------------------------------------------------------
# Consensus: per field, majority vote across models; confidence by agreement level.
# ---------------------------------------------------------------------------
def consensus_for_pass(task, pass_name, llm_out, models):
    parser = PARSERS.get(task)
    if parser is None:
        sys.exit(f"aggregate: no parser registered for task '{task}'")

    # per_id[id][field] = list of values (one per model that produced a parse)
    per_id_fields = defaultdict(lambda: defaultdict(list))
    per_id_errors = defaultdict(int)
    all_ids = set()

    for model in models:
        outdir = os.path.join(llm_out, pass_name, model)
        recs = load_model_output(outdir)
        for pid, r in recs.items():
            all_ids.add(pid)
            if r["error"]:
                per_id_errors[pid] += 1
                continue
            fields = parser(r["resp"], no_grammar=r["no_grammar"])
            for k, v in fields.items():
                per_id_fields[pid][k].append(v)

    n_models = len(models)
    rows = []
    for pid in sorted(all_ids):
        row = {"ID": pid, "n_models": n_models, "n_errors": per_id_errors.get(pid, 0)}
        max_agree = 0
        for field, values in per_id_fields[pid].items():
            counts = Counter(values)
            value, votes = counts.most_common(1)[0]
            row[field] = value
            row[f"{field}__votes"] = votes
            max_agree = max(max_agree, votes)
        # confidence from the strongest-supported field's agreement
        if max_agree >= n_models:
            row["confidence"] = "high"
        elif max_agree >= (n_models // 2 + 1):
            row["confidence"] = "medium"
        elif max_agree > 0:
            row["confidence"] = "low"
        else:
            row["confidence"] = "none"  # all models errored / unparsed
        rows.append(row)
    return {r["ID"]: r for r in rows}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--task", required=True)
    ap.add_argument("--llm-out", required=True, help="runtime/<task>/llm_out dir")
    ap.add_argument("--passes", required=True, help="comma-separated pass names")
    ap.add_argument("--models", required=True, help="comma-separated model names")
    ap.add_argument("--out", required=True, help="results.csv path")
    args = ap.parse_args()

    passes = [p.strip() for p in args.passes.split(",") if p.strip()]
    models = [m.strip() for m in args.models.split(",") if m.strip()]

    # Consensus per pass, then merge passes on ID (different passes contribute different fields).
    merged = defaultdict(dict)
    for p in passes:
        table = consensus_for_pass(args.task, p, args.llm_out, models)
        for pid, row in table.items():
            for k, v in row.items():
                if k == "ID":
                    merged[pid]["ID"] = pid
                elif len(passes) > 1:
                    merged[pid][f"{p}__{k}"] = v  # namespace fields by pass when >1 pass
                else:
                    merged[pid][k] = v

    fieldnames = []
    for row in merged.values():
        for k in row:
            if k not in fieldnames:
                fieldnames.append(k)

    tmp = args.out + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for pid in sorted(merged):
            w.writerow(merged[pid])
    os.replace(tmp, args.out)
    print(f"aggregate: wrote {len(merged)} rows -> {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
