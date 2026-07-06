-- Colectomy note pull.
-- Final result set MUST be exactly: PatientID, EntryDateTime, NoteID, ReportText
-- Fill in <DATABASE> and <SCHEMA> for your environment (IBD cohort + NoteTable).
-- Ported from reproduce_results/colectomy_ascertainment/step1_get_ibd_pts_colectomy_notes.sql
SET NOCOUNT ON;
USE <DATABASE>;

-- IBD cohort patient IDs.
-- {SLICE_FILTER} is replaced by db.py: empty when not slicing, or a stateless SHA2_256 hash
-- partition on PatientID to pull only bucket i of N (see run_task.sh --slices).
drop table if exists #patID;
select PatientID into #patID
from <SCHEMA>.Cohort
where 1=1 {SLICE_FILTER};

-- All notes for those patients (do this first to speed up the full-text search)
drop table if exists #patNotes;
select notes.NoteID, notes.EntryDateTime, notes.PatientID
into #patNotes
from <SCHEMA>.NoteTable as notes
join #patID on #patID.PatientID = notes.PatientID;

-- Notes matching colectomy-related terms
drop table if exists #notesMatch;
select pt.PatientID, pt.EntryDateTime, pt.NoteID
into #notesMatch
from <SCHEMA>.FullTextSearch('"colectomy" OR
NEAR(colon, resection, 10, FALSE) OR NEAR(colon, removal, 10, FALSE) OR
NEAR(rectum, resection, 10, FALSE) OR NEAR(rectum, removal, 10, FALSE) OR
NEAR(rectal, resection, 10, FALSE) OR NEAR(rectal, removal, 10, FALSE) OR
"proctocolectomy" OR "hemicolectomy" OR "sigmoidectomy" OR "proctectomy" OR "rectosigmoidectomy" OR
"ileocecectomy" OR NEAR(ileocecal, resection, 10, FALSE) OR NEAR(ileocecal, removal, 10, FALSE) OR
"hartmann*" OR
"ileostomy" OR "colostomy" OR "anastomosis" OR "pouch construction" OR "j-pouch"') as search
join #patNotes as pt on pt.NoteID = search.NoteID;

-- Final result set with note text
SELECT m.PatientID, m.EntryDateTime, m.NoteID, notes.ReportText
FROM #notesMatch as m
JOIN <SCHEMA>.NoteTable as notes on notes.NoteID = m.NoteID
ORDER BY m.PatientID, m.EntryDateTime;
