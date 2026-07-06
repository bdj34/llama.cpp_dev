#!/usr/bin/env python3
"""
Shared SQL Server access for the pipeline. Streams notes so we never materialize the whole
notes.csv on disk (or in memory) — make_inputs.py consumes the generator and keeps only the
extracted snippets.

Auth is Kerberos (Trusted_Connection=Yes) — run kticket first (run_task.sh does).
Connection via environment (set on the GPU box):
    PHENO_SQL_SERVER   e.g. "MYSQLSERVER.va.gov"
    PHENO_SQL_DB       e.g. "ORD_MyStudy"
    PHENO_SQL_DRIVER   optional, default "{ODBC Driver 17 for SQL Server}"

The SQL's final result set MUST be: PatientID, EntryDateTime, NoteID, ReportText
"""
import os
import sys

EXPECTED_COLS = ["PatientID", "EntryDateTime", "NoteID", "ReportText"]


def iter_notes(sql_path, fetch_size=5000, slice_i=None, slice_n=None):
    """Yield dict rows {PatientID, EntryDateTime, NoteID, ReportText} streamed from SQL Server.

    Cohort slicing: if slice_n > 1, the SQL's {SLICE_FILTER} placeholder is replaced with a
    server-side predicate selecting only patients in bucket slice_i of slice_n (a deterministic
    hash partition on PatientID), so each pull fetches ~1/N of the cohort. The SQL MUST contain
    {SLICE_FILTER} (e.g. `... WHERE 1=1 {SLICE_FILTER}` on the cohort select). When not slicing,
    {SLICE_FILTER} is replaced with the empty string.
    """
    server = os.environ.get("PHENO_SQL_SERVER")
    database = os.environ.get("PHENO_SQL_DB")
    driver = os.environ.get("PHENO_SQL_DRIVER", "{ODBC Driver 17 for SQL Server}")
    if not server or not database:
        sys.exit("db: set PHENO_SQL_SERVER and PHENO_SQL_DB in the environment.")

    import pyodbc

    with open(sql_path, encoding="utf-8") as f:
        query = f.read()

    if slice_n and slice_n > 1:
        if "{SLICE_FILTER}" not in query:
            sys.exit(f"db: --slices requested but {sql_path} has no {{SLICE_FILTER}} placeholder "
                     "(add e.g. `WHERE 1=1 {SLICE_FILTER}` to the cohort select).")
        # Stateless hash partition: a patient's bucket depends only on PatientID, so each slice
        # query is independent (no shifting if the cohort changes between pulls). SHA2_256 gives
        # a uniform distribution; ((h % N) + N) % N keeps the bucket non-negative WITHOUT ABS
        # (ABS(CHECKSUM(...)) can overflow on INT_MIN, and CHECKSUM distributes poorly).
        n, i = int(slice_n), int(slice_i)
        filt = (f"AND (CONVERT(BIGINT, HASHBYTES('SHA2_256', CONVERT(VARCHAR(64), PatientID))) "
                f"% {n} + {n}) % {n} = {i}")
    else:
        filt = ""
    query = query.replace("{SLICE_FILTER}", filt)

    conn_str = (
        f"DRIVER={driver};SERVER={server};DATABASE={database};"
        "Trusted_Connection=Yes;Encrypt=Yes;TrustServerCertificate=Yes"
    )
    print(f"[db] connecting to {server}/{database} (Kerberos)", file=sys.stderr)
    conn = pyodbc.connect(conn_str, autocommit=True)
    try:
        cur = conn.cursor()
        cur.execute(query)
        # Advance past non-row-returning statements (SELECT INTO temp tables) to the final SELECT.
        while cur.description is None:
            if not cur.nextset():
                sys.exit("db: query produced no row-returning result set (expected a final SELECT)")
        cols = [d[0] for d in cur.description]
        if cols[:4] != EXPECTED_COLS:
            sys.exit(f"db: query must return columns {EXPECTED_COLS}, got {cols[:4]}")

        n = 0
        while True:
            rows = cur.fetchmany(fetch_size)
            if not rows:
                break
            for r in rows:
                edt = r[1]
                if hasattr(edt, "strftime"):
                    edt = edt.strftime("%Y-%m-%d %H:%M:%S")
                elif edt is None:
                    edt = "NULL"
                else:
                    edt = str(edt)
                yield {"PatientID": str(r[0]), "EntryDateTime": edt,
                       "NoteID": str(r[2]), "ReportText": r[3] or ""}
                n += 1
        print(f"[db] streamed {n} notes", file=sys.stderr)
    finally:
        conn.close()
