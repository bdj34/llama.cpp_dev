#!/usr/bin/env python3
"""
Optional debug tool: dump notes for a task's SQL to a CSV for inspection.

The pipeline itself no longer writes a notes.csv — run_task.sh streams notes straight from SQL
into make_inputs.py (see db.py / make_inputs.py --sql). This script is just for eyeballing a
query's output, e.g.:

    kticket
    export PHENO_SQL_SERVER=... PHENO_SQL_DB=...
    python3 db_pull.py --sql ../sql/colectomy.sql --out /tmp/sample.csv --limit 50
"""
import argparse
import csv
import os
import sys

import db  # same dir


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sql", required=True, help="path to sql/<task>.sql")
    ap.add_argument("--out", required=True, help="output CSV path")
    ap.add_argument("--limit", type=int, default=0, help="stop after N rows (0 = all)")
    args = ap.parse_args()

    n = 0
    tmp = args.out + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        for row in db.iter_notes(args.sql):
            w.writerow([row["PatientID"], row["EntryDateTime"], row["NoteID"], row["ReportText"]])
            n += 1
            if args.limit and n >= args.limit:
                break
    os.replace(tmp, args.out)
    print(f"db_pull: wrote {n} notes -> {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
