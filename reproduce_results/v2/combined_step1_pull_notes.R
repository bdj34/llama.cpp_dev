# =====================================================================
# combined_step1_pull_notes.R
# Pulls ReportText in NoteDateTime windows (efficient: the note table
# is indexed on NoteDateTime), but WRITES into N patient-hash buckets
# rather than per-window files. Every note for a patient hashes to the
# same bucket regardless of date, so each bucket holds complete
# patients -- letting python aggregate per patient by reading ONE
# bucket at a time instead of all CSVs at once.
#
# Why not sort/chunk by PatientID in SQL: the text pull is windowed by
# date for the range seek, so a patient is split across windows; a SQL
# ORDER BY / patient-index can't make a patient contiguous across those
# windows without giving up the date seek. The bucketing is therefore
# done here in R, piggybacked on the loop (one window in RAM at a time,
# unchanged memory).
#
# Resume: a per-window .done marker guards each window, since buckets
# are shared append targets and a naive re-run would double-append.
#
# Prereq: combined_step1_get_all_notes_one_pass.sql run once in SSMS
# (creates <SCHEMA>.notePull_cohort and <SCHEMA>.matchingNotes_all).
#
# Downstream: python reads one bucket_*.csv at a time, groups by
# PatientID, cuts snippets around matched terms, concatenates for LLM.
# =====================================================================

library(DBI)
library(odbc)
library(data.table)   # fwrite: multithreaded CSV write, much faster than readr

con <- dbConnect(odbc::odbc(),
                 Driver             = "ODBC Driver 17 for SQL Server",
                 Server             = "<SERVER>",
                 Database           = "<DATABASE>",
                 Trusted_Connection = "yes")
# NOTE: no encoding= argument needed. ReportText is CAST to NVARCHAR in
# the SQL template, so the driver returns it as Unicode and odbc hands
# R proper UTF-8. The decode is done server-side, not here.

# --- text sanitizer --------------------------------------------------
# ReportText already arrives as valid UTF-8 (server-side NVARCHAR cast),
# so NO code-page decoding happens here -- this only tidies characters
# for a clean CSV round-trip into python, in TWO passes:
#   1. Normalize CRLF / lone CR to \n. Embedded newlines are legal in
#      quoted CSV fields; data.table quotes them and pandas' C engine
#      reads them back fine.
#   2. Replace C0 + DEL + C1 control chars EXCEPT \n and \t (vertical
#      tab, form feed, DEL -- common CPRS artifacts) with spaces so
#      offsets shift predictably and no parser chokes.
# The old iconv UTF-8->UTF-8 "insurance" pass and the separate C1 gsub
# were dropped/merged -- going from 4 passes to 2 was the big speedup.
# (If a stray invalid byte ever makes gsub error, add iconv(x, "UTF-8",
# "UTF-8", sub=" ") back as a first line.)
clean_note_text <- function(x) {
  x <- gsub("\r\n|\r", "\n", x, perl = TRUE)
  x <- gsub("[\\x01-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F\\x{80}-\\x{9F}]",
            " ", x, perl = TRUE)
  x
}

# --- per-window text pull (inlined; paste0 fills the dates) ----------
# The combined search already ran once
# (combined_step1_get_all_notes_one_pass.sql) into
# <SCHEMA>.matchingNotes_all. This only fetches ReportText for one
# window. CAST -> NVARCHAR makes SQL Server decode server-side using the
# column collation, so R receives proper UTF-8 (no code-page handling).
# The NoteDateTime bound is on BOTH sides of the join so NoteTable gets
# a range seek on its NoteDateTime index instead of millions of NoteID
# lookups.
build_query <- function(start_dt, end_dt) {
  paste0(
"SET NOCOUNT ON;
use <DATABASE>;

select
	m.PatientID, m.NoteDateTime, m.NoteID,
	CAST(notes.ReportText AS NVARCHAR(MAX)) as ReportText
from <SCHEMA>.matchingNotes_all as m
join <SCHEMA>.NoteTable as notes
	on notes.NoteID = m.NoteID
where m.NoteDateTime     >= '", start_dt, "' and m.NoteDateTime     < '", end_dt, "'
  and notes.NoteDateTime >= '", start_dt, "' and notes.NoteDateTime < '", end_dt, "'
order by m.PatientID, m.NoteDateTime;
")
}

# Catch-all for notes the date windows can NEVER hit: NoteDateTime is
# NULL (every >=/< comparison is UNKNOWN -> excluded from all windows) or
# falls outside [date_min, date_max). Without this those notes are
# silently never pulled. No date bound on the notes side here (the set
# is small; the point is just to sweep the stragglers).
build_query_leftover <- function(date_min, date_max) {
  paste0(
"SET NOCOUNT ON;
use <DATABASE>;

select
	m.PatientID, m.NoteDateTime, m.NoteID,
	CAST(notes.ReportText AS NVARCHAR(MAX)) as ReportText
from <SCHEMA>.matchingNotes_all as m
join <SCHEMA>.NoteTable as notes
	on notes.NoteID = m.NoteID
where m.NoteDateTime is null
   or m.NoteDateTime <  '", date_min, "'
   or m.NoteDateTime >= '", date_max, "'
order by m.PatientID;
")
}

# --- windows ---------------------------------------------------------
# Tune window_by so each window's final SELECT completes reliably.
# Use the per-year note counts from the setup script to decide; note
# volume grows over time, so quarterly is a reasonable start and you
# can switch to monthly for recent years if needed.
date_min  <- as.Date("1999-10-01")
date_max  <- as.Date("2026-07-15")   # exclusive upper bound of last window
window_by <- "3 months"

starts <- seq(date_min, date_max, by = window_by)
ends   <- c(starts[-1], date_max)

out_dir  <- "note_buckets"
done_dir <- file.path(out_dir, ".done")
dir.create(done_dir, showWarnings = FALSE, recursive = TRUE)

# --- patient -> bucket -----------------------------------------------
# N buckets: choose so one bucket (~1/N of all matched notes) fits in
# python's RAM for a groupby. Deterministic in PatientID, so a patient
# always lands in the same bucket across every date window.
N_BUCKETS <- 50
bucket_of <- function(pid) {
  # VA PatientID is integer-valued; as.numeric (double) is exact well
  # past its range, and modulo is stable across windows. If IDs are ever
  # non-numeric, swap in a string hash (e.g. digest::digest2int).
  as.integer(as.numeric(pid) %% N_BUCKETS)
}

# Write each bucket's slice of THIS window as its own GZIP SHARD (no
# append -- gzip append is unreliable). Filenames carry the window tag,
# so a rerun just overwrites its own shards (idempotent, no double-write)
# and Python reads every shard sharing a "bucket_NN__" prefix together.
# gzip shrinks clinical-text CSV ~5-8x, which fixes the storage limit and
# makes the Windows->Linux transfer smaller in one step.
#   split() partitions the frame in one pass; na="" keeps SQL NULLs as
#   empty strings; eol="\n" forces LF so the Linux side sees Unix line
#   endings; compress="gzip" needs data.table >= 1.14.0 (check
#   packageVersion("data.table")).
write_buckets <- function(df, tag) {
  cols  <- setdiff(names(df), "bucket")
  parts <- split(df[cols], df$bucket)
  for (b in names(parts)) {
    f <- file.path(out_dir,
                   paste0("bucket_", sprintf("%02d", as.integer(b)),
                          "__", tag, ".csv.gz"))
    fwrite(parts[[b]], f, na = "", eol = "\n", compress = "gzip")
  }
}

# Clean text, type IDs, assign buckets, write this window's gzip shards.
process_and_write <- function(df, tag) {
  if (nrow(df) == 0) return(invisible())
  df$ReportText <- clean_note_text(df$ReportText)
  # IDs as character so python never reads them as floats
  df$PatientID <- as.character(df$PatientID)
  df$NoteID    <- as.character(df$NoteID)
  df$bucket    <- bucket_of(df$PatientID)
  # na = "": SQL NULLs -> empty strings, and note text "NA" is never
  # confused with missingness on either side of the round-trip.
  write_buckets(df, tag)
}

# --- loop ------------------------------------------------------------
for (i in seq_along(starts)) {
  start_dt <- format(starts[i], "%Y-%m-%d")
  end_dt   <- format(ends[i],   "%Y-%m-%d")
  marker   <- file.path(done_dir, paste0(start_dt, "_to_", end_dt, ".done"))

  if (file.exists(marker)) next  # window already committed to buckets

  message(paste0(Sys.time(), "  pulling ", start_dt, " -> ", end_dt))
  t0 <- Sys.time()

  df <- dbGetQuery(con, build_query(start_dt, end_dt))

  message(paste0("  ", nrow(df), " notes in ",
                 round(difftime(Sys.time(), t0, units = "mins"), 1), " min"))

  process_and_write(df, paste0(start_dt, "_to_", end_dt))

  # Marker written only after shards are written, so a crash mid-write
  # leaves the window un-marked and it is safely retried on rerun (the
  # rerun overwrites this window's shards -- unique names, idempotent).
  file.create(marker)
}

# --- leftover pass: NULL-dated + out-of-[date_min,date_max) notes ----
# The date windows can never match these, so sweep them once here.
leftover_marker <- file.path(done_dir, "leftover_null_or_out_of_range.done")
if (!file.exists(leftover_marker)) {
  message(paste0(Sys.time(), "  pulling leftover (NULL / out-of-range dates)"))
  df <- dbGetQuery(con, build_query_leftover(format(date_min, "%Y-%m-%d"),
                                             format(date_max, "%Y-%m-%d")))
  message(paste0("  ", nrow(df), " leftover notes"))
  process_and_write(df, "leftover")   # if huge, chunk it by PatientID range
  file.create(leftover_marker)
}

dbDisconnect(con)

# Quick audit: compressed bytes per shard
files <- list.files(out_dir, pattern = "^bucket_.*\\.csv\\.gz$", full.names = TRUE)
audit <- data.frame(file  = basename(files),
                    bytes = file.size(files))
print(audit)
