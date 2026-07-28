# Phenotyping inference queue

A minimal, crash-proof way to run a batch of LLM extraction jobs on the GPU box and walk away.
Preprocessing is a **separate** step (see [python/preprocessing/](python/preprocessing/)); this half only runs
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
2. Make the inputs with the extractors, e.g. `python/preprocessing/extract_ibd.py --buckets ... --out-dir /data/pheno/ibd`
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
./queue.sh add-all --force                       # ... or rewrite the manifest to match jobs.conf (drops stale keys after you edit rows/replicates)
./queue.sh add ibd gemma4-26B-A4B-thinking 1     # ... or enqueue one job
./queue.sh list                                  # show the manifest
./queue.sh start                                 # launch workers (both cards by default) / resume
./queue.sh stop                                  # stop GRACEFULLY (workers exit after the current job)
./queue.sh kill                                  # stop NOW: kill workers + inference immediately (prompts y/N; -y to skip)
```
`stop` only sets a flag and waits for the current inference to finish; use `kill` when you need to
interrupt mid-inference. To change a job's **args**, just edit `config/jobs.conf` and re-run — args
are read at launch, so no `add-all` is needed (use `add-all --force` only when you change *which
jobs exist*: added/removed rows or changed replicate/retry).
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
*/5 * * * * /ABS/PATH/phenotyping/queue.sh reap      >> /ABS/PATH/phenotyping/runtime/cron.log 2>&1
```
This covers both a full reboot and the "processes killed, box stays up" case. A job interrupted
partway through simply resumes from the IDs already written (rows are flushed per-ID, so nothing
beyond the in-flight batch is redone).

The optional `reap` line is a **stuck-worker watchdog**: if a worker is alive but **no**
`llama-data-extraction` has run for N consecutive checks (default 3, so ~15 min at this cadence),
it kills the worker so the next `worker` tick starts a fresh one and reclaims the card. Any inference
on any card resets the counter, so it only fires when the queue is genuinely idle-but-not-exited.
It's a backstop to `run_one`'s own teardown-hang watchdog (which kills an inference that spins after
finishing, e.g. a CUDA-teardown hang) — together they let a wedged card recover without a manual
`kill`. Tune with `reap <N>`.

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

## Consensus pre-filter (reviewer jobs)

A task's two small models each answer the same patients from their own `inputs_<r>.txt` subsample;
a **reviewer** job (a bigger model, its own `<task>_rerun` row) then adjudicates. It should only
read the patients the two disagreed on, and it does — for free, through the same resume rule.

`between_jobs.sh` waits until **both** small-model jobs are complete (every ID in their
`IDs_<r>.txt` appears in their `output_*.txt`), then runs `python/between_jobs/skip_consensus_<task>.py`,
which writes `output_consensus_<datetime>.txt` into the **reviewer's** outDir with one
`consensus_reached\t<ID>` row per agreed ID. Those IDs now look done to the reviewer job, so it
processes only the rest. Run it before the reviewer job starts; it is idempotent (each block
no-ops once the file exists) and is meant for your crontab next to the workers:
```
*/5 * * * * /ABS/PATH/phenotyping/between_jobs.sh >> /ABS/PATH/phenotyping/runtime/between_jobs.log 2>&1
```
**What counts as agreement is per task**, so each task gets its own `skip_consensus_<task>.py` with
an AGREEMENT RULES block at the top — the only part meant to be edited. CRC and IBD differ today
(e.g. IBD sends two `"uncertain"` verdicts to the reviewer; CRC lets two `"not_documented"` sites
agree), which is deliberate. Check a rule change with `--dry-run` first: it prints how many IDs
agreed and which field drove each disagreement, and `--examples N` shows sample pairs.

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

## Note on changing RESULTS_ROOT mid-run

`RESULTS_ROOT` (in `lib.sh`) is where **all** resume state lives. Don't change it while jobs are in
flight: a running job keeps writing to the old root (it read `lib.sh` at launch), while new runs read
and write the new root — so previously-completed jobs look un-done there and get **reprocessed**, and
your output ends up split across two directories. If you must move it, do it with the queue stopped
and move the existing `results/<task>/<model>/rep*` dirs into the new root so resume still sees them.

## Layout

- `config/` — `jobs.conf` (one row per task x model).
- `run_one.sh` — the idempotent single-job unit (filter to remaining -> run, under the GPU lock).
- `queue.sh` — manifest + per-card workers (`add`/`add-all`/`start`/`stop`/`kill`/`reap`/`list`/`errors`/`worker`).
- `lib.sh` — config lookup, logging, GPU lock.
- `runtime/` — coordination state only (GPU lock, `_queue/` manifest + worker log); gitignored.
- `results/` (or your `RESULTS_ROOT`) — per-job output dirs.
- `python/preprocessing/` — the standalone input builders (`extract_*.py`, `snippet_lib.py`).
- `python/between_jobs/` — the per-task `skip_consensus_<task>.py` rules.
- `between_jobs.sh` — the between-stage step (see [Consensus pre-filter](#consensus-pre-filter-reviewer-jobs)):
  once a task's two small models are done, marks the IDs they agreed on so the reviewer skips them.
