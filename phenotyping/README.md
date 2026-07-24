# Phenotyping inference queue

A minimal, crash-proof way to run a batch of LLM extraction jobs on the GPU box and walk away.
Preprocessing is a **separate** step (see [python/](python/)); this half only runs
`llama-data-extraction` and is designed to survive the GPU being shut down for maintenance mid-run.

## Model

The whole thing rests on one idea: **all resume state lives on disk in the results directory.**
`llama-data-extraction` writes a timestamped `output_<datetime>.txt` per run into its `--outDir`,
with one tab-separated row per input (`<answer>\t<ID>`, or `Error\t<ID>`). So "which IDs are done"
is just "which IDs already appear in those files." Every job is therefore idempotent: re-running it
recomputes what's left and continues. No `.done` markers, no checkpoints, nothing to corrupt.

A **job** is one line: `<task> <model> <replicate> <retry>` (retry `T`/`F`). Its output goes to
`results/<task>/<model>/rep<r>/` (so a model run over multiple replicates, or thinking vs
non-thinking variants, never collide).

## Prerequisites

1. Build the tool: `../build/bin/llama-data-extraction`.
2. Make the inputs with the extractors, e.g. `python/extract_ibd.py --buckets ... --out-dir /data/pheno/ibd`
   (produces `inputs_<r>.txt` + `IDs_<r>.txt`).
3. Fill in config/jobs.conf (one row per task x model).
4. `flock` (standard on Linux) enables the per-worker singleton + per-card locks; without it there's
   an automatic `mkdir` fallback, so it's still safe.

## Config

One file, `config/jobs.conf` — one row per **job = (task, model, replicate, retry)**:
```
task | model | replicate | retry | gguf | prompt_dir | promptFormat | grammar | input_dir | args
```
Each row fully specifies a job, so `./queue.sh add-all` enqueues every row. `replicate` is the
consensus assignment (give a task's models different replicates so they read the complementary
`inputs_<r>.txt` subsamples). This is the right granularity because most inference args depend on
**both**: a task's input length against a model's VRAM sets `--ctx-size`/`--parallel`, and the task's
answer length plus the model's thinking mode sets `--n-predict`. Thinking vs non-thinking also use a
different `grammar` and `promptFormat` — all per-row here, so a variant is just another row.

- `retry` → `T` or `F`, part of the key. `F` = normal run. `T` = a separate row (same
  task/model/replicate, `retry=T`) that reprocesses only this job's error-only IDs with that row's
  settings (see [Errors](#errors-handled-manually)).
- `prompt_dir` → system prompt `system_prompts/<prompt_dir>/<task>.txt`.
- `promptFormat` → `--promptFormat` (must be tool-recognized).
- `args` → inference flags for this job (`--ctx-size`, `--parallel`, `--n-predict`, `--batch-size`,
  `--n-gpu-layers`, `--temp` + thinking `--top-k`/`--top-p`, `--no-escape`, `--swa-full`). **No GPU
  placement** and no `--promptFormat` (own column): every job runs on **one card** automatically —
  the per-card worker's card under the queue, or card 0 for a bare `run_one.sh` without `--gpu`.

The model fields repeat across a model's tasks and the task fields across a task's models — the cost
of one self-contained line per job.

## Running

```bash
./queue.sh add-all                               # enqueue EVERY job row in config/jobs.conf
./queue.sh add ibd gemma4-26B-A4B-thinking 1     # ... or enqueue one job
./queue.sh list                                  # show the manifest
./queue.sh start                                 # launch workers (both cards by default) / resume
./queue.sh stop                                  # stop after the current job
```
You can also run a single job directly, resumable on its own:
```bash
./run_one.sh ibd gemma4-26B-A4B-thinking 1
```

### How the workers use the GPUs

Every job runs on **one card**. `./queue.sh start` launches **one worker per card** (default cards
`0,1`), so both GPUs run *different* jobs at once; when a card frees up its worker immediately claims
the next unclaimed job (jobs are locked so the two cards never run the same one). This keeps both
cards saturated — it's the normal mode and needs no flags.

Override the card set with the `CARDS` env var or `--cards`: `CARDS=0 ./queue.sh start` (or
`./queue.sh start --cards 0`) for a single-GPU box, or `--cards 0,1,2,3` for four cards.

## Resume after maintenance (no root needed)

Because state is on disk, resuming is just running the worker again. Put this in your **own**
crontab (`crontab -e`, no sudo) — `worker` (not `start`) so a pending `stop` is respected, and it
no-ops if a worker is already running or everything is done. One line per card:
```
*/5 * * * * /ABS/PATH/phenotyping/queue.sh worker 0  >> /ABS/PATH/phenotyping/runtime/cron.log 2>&1
*/5 * * * * /ABS/PATH/phenotyping/queue.sh worker 1  >> /ABS/PATH/phenotyping/runtime/cron.log 2>&1
```
This covers both a full reboot and the "processes killed, box stays up" case. A job interrupted
partway through simply resumes from the IDs already written (rows are flushed per-ID, so nothing
beyond the in-flight batch is redone).

## Errors (handled manually)

The tool isolates per-input failures (one bad input can't crash a run) and writes `Error\t<ID>`;
grammar runaways are auto-retried grammar-free. Normal resume treats an errored ID as done, so it is
**not** retried automatically.
```bash
./queue.sh errors                        # report error-only IDs per job
```
To re-run a job's failures — optionally **with different settings** — add a **second row** for it
with `retry=T` (same `task/model/replicate`, new `args`/`promptFormat`/`gguf`), then re-run the
queue. A `T` job reprocesses only the error-only IDs (successful IDs untouched) and writes to the
same outDir. Both rows are enqueued by `add-all`; each queue run does one retry pass, so remove the
`T` row (or leave it — it no-ops once there are no errors) when you're done. Add `T` rows *after* the
`F` run has produced errors. `./run_one.sh <task> <model> <rep>` runs the `F` row; add `T` as a 4th
arg (`./run_one.sh ibd gemma 1 T`) to run the retry row directly.

## What gets recorded (per run)

In each `results/<task>/<model>/rep<r>/`:
- `output_<datetime>.txt` — the answers (`<answer>\t<ID>`), the resume source of truth.
- `invocation_<datetime>.txt` — the **exact command** `run_one` executed (every flag/value).
- `metadata_<datetime>.txt` — written by the tool: the prompt used **and** the fully-resolved
  sampling parameters (`params.sampling.print()`, including defaults you didn't set).
- `log_<datetime>.txt` — the tool's run log.

Together, `invocation_*` (what we ran) + `metadata_*` (resolved sampler + prompt) fully document each
batch. A resume produces a new set of these files alongside the old ones.

## Note on editing prompts mid-queue

The prompt file is read when a job's process launches, not when it's queued — so you can edit a
task's prompt any time before its job starts and it will be picked up. If you edit a prompt *after*
that job has already produced outputs, the finished IDs keep the old prompt and only the remaining
ones get the new one; to reprocess uniformly, delete that `results/<task>/<model>/rep<r>/` first.

## Layout

- `config/` — `jobs.conf` (one row per task x model).
- `run_one.sh` — the idempotent single-job unit (filter to remaining -> run, under the GPU lock).
- `queue.sh` — manifest + single worker (`add`/`start`/`stop`/`list`/`errors`/`rerun-errors`).
- `lib.sh` — config lookup, logging, GPU lock.
- `runtime/` — coordination state only (GPU lock, `_queue/` manifest + worker log); gitignored.
- `results/` (or your `RESULTS_ROOT`) — per-job output dirs.
- `python/` — the standalone input builders (`extract_*.py`, `snippet_lib.py`).
