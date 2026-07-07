# Phenotyping pipeline

Self-contained, single-entrypoint LLM phenotyping pipeline. Supersedes the per-variable
copy-pasted scripts in `../reproduce_results/`. Runs entirely on the GPU box.

Each **task** (an extraction *domain*) runs end-to-end via one command:

```bash
./run_task.sh <task> --out-root DIR [--resume|--from STEP|--slices N|--force|--dry-run|--retry-errors]
```

`--out-root DIR` is **required** — it's the root for all of the task's working data
(`DIR/<task>/`: inputs, LLM outputs, results, markers, logs). Pass it consistently across a
task's runs so resumes find their state.

Steps (each guarded by a `.done` marker so a crash resumes by re-running the same command):

1. **preprocess** — streams notes from SQL Server over Kerberos (`kticket` once) *directly*
   into `python/make_inputs.py` (regex snippet extraction + chat formatting) → sharded
   `input.txt` / `ptIDs.txt` per pass. No `notes.csv` is written. *(The only DB interaction.)*
2. **infer** — `../build/bin/llama-data-extraction` per pass, grouped by model (each GGUF
   loads once). Per-`(pass,model)` `.done` markers.
3. **aggregate** — `python/aggregate.py` per-field consensus across models → `results.csv`.

## Tasks

| task | notes | extracts |
| :--- | :--- | :--- |
| `colonoscopy_report` | VA colonoscopy reports + linked pathology | all endoscopic + pathology findings (gate → link → merged extraction) |
| `colonoscopy_timing`  | GP/progress notes | external/internal colonoscopy occurrence + date |
| `ibd`                 | IBD-dx notes | diagnosis type + confirmation + year |
| `colectomy`           | colectomy notes | yes/no + type + segments + date |
| `crc`                 | CRC free-text notes | yes/no + confidence + date |

## Layout

- `config/models.conf` — model registry (gguf path, format, ctx, parallel, n_predict, …).
- `config/<task>.conf` — per-task passes, grammars, prompts, models, consensus rule.
- `sql/<task>.sql` — parameterized note-pull query.
- `python/` — `db.py` (streams notes from SQL), `make_inputs.py` (preprocess, `--sql` streams
  or `--notes` CSV), `aggregate.py` (consensus). `db_pull.py` is an optional CSV sample-dumper.
- `lib.sh` — shared bash helpers (logging, step runner, kinit, sharding).
- **Task data** goes under the required `--out-root DIR` (`DIR/<task>/`) — put this on a data
  disk outside the repo, e.g. `./run_task.sh colectomy --out-root /data/pheno`.
- `runtime/` (in-repo, gitignored) holds only small **coordination state**: the GPU lock and the
  queue metadata. It is *not* where the large per-task files go.

## Running multiple tasks (GPU queue)

Each task already maximizes GPU use (per-model `split`/`dual` in `models.conf`), so tasks
should run **one at a time**. `queue.sh` is a foolproof single-worker FIFO queue:

```bash
./queue.sh add colectomy --out-root /data --slices 6          # enqueue one task
./queue.sh add "colectomy --out-root /data" "ibd --out-root /data"   # several: quote each entry
./queue.sh list                     # show running + pending
./queue.sh stop                     # stop the worker after the current task finishes
```
(Each queued task must include `--out-root` — the queue reuses it for the task's full run and
its prep-ahead automatically.)

The next task starts the instant the current one finishes. The worker survives terminal
close, and a worker/box crash is safe — the interrupted task is re-queued and **resumes from
its last `.done` marker**. Two layers of serialization make it foolproof:
1. **queue.sh** — a single worker runs tasks FIFO (ordering + auto-next).
2. **run_task.sh** — a `flock` GPU mutex around the infer step, so no two inferences ever
   share the GPUs even outside the queue (e.g. a hand-launched run or an orphaned task).

**Prep-ahead (no GPU idle between tasks):** while the current task is on the GPU, the worker
runs the *next* task's SQL pull + preprocessing in the background (`run_task.sh <next>
--until preprocess`). When the current task finishes, the next goes straight to inference —
the GPU never sits idle waiting for a DB pull. Bounded to one task ahead; disable with
`QUEUE_PREP_AHEAD=0`. (`run_task.sh --until <step>` runs through a step then stops.)

## Large cohorts (`--slices N`)

When the cohort is too big for a single SQL pull, partition it into N buckets:

```bash
./run_task.sh colectomy --out-root /data --slices 8
```

Each bucket is pulled separately (server-side `ABS(CHECKSUM(PatientID)) % N`, so each pull
fetches ~1/N of patients) and produces its own `sliceK/{system,input,ptIDs}.txt`. Inference
then runs **per slice** with per-`(pass,model,slice)` `.done` markers, so a crash on a huge
cohort resumes at the current slice rather than restarting. `aggregate.py` unions all slices
(disjoint patient sets) into one `results.csv`. The slice count is persisted per task, so
resumes stay consistent; `--force` regenerates. Requires a `{SLICE_FILTER}` placeholder on the
cohort select in `sql/<task>.sql` (see `sql/colectomy.sql`). Composes with `dual` GPU mode
(each slice is further split across GPUs).

## Robustness (unattended multi-week runs)

- **Per-input fault tolerance** in `llama-data-extraction`: a per-pass `--n-predict` cap stops
  grammar-driven runaway generation; the offending input is automatically re-run **grammar-free**
  and its raw output captured (tagged `NO_GRAMMAR`) for lenient parsing. Hard failures are logged
  `Error\t<ID>` instead of crashing the run.
- `--retry-errors` re-runs only the IDs that failed.
- Flash attention is forced on (`-fa on`) to match prior runs (upstream default is now `auto`).
