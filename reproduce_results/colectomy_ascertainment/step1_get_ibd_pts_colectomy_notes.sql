use <DATABASE>;

-- Filter by baseTabl to only get patients with IBD
drop table if exists #patID;
select PatientID, base.* into #patID from <SCHEMA>.Cohort as coh 
join <SCHEMA>.baseTable_with_llms as base
on coh.PatientID = base.PatientID
create clustered columnstore index cci on #patID;

-- Select all note IDs for patient(s). Doing this ahead of time will speed up the text search.
drop table if exists #patNotes;
Select notes.NoteID, notes.EntryDateTime, #patID.*
into #patNotes
From <SCHEMA>.NoteTable as notes
join #patID 
	on #patID.PatientID = notes.PatientID
create clustered columnstore index cci on #patNotes;

-- Cut down to notes that match
drop table if exists #notesMatch;
select pt.*
into #notesMatch
from <SCHEMA>.FullTextSearch('"colectomy" OR
NEAR(colon, resection, 10, FALSE) OR NEAR(colon, removal, 10, FALSE) OR 
NEAR(rectum, resection, 10, FALSE) OR NEAR(rectum, removal, 10, FALSE) OR
NEAR(rectal, resection, 10, FALSE) OR NEAR(rectal, removal, 10, FALSE) OR
"proctocolectomy" OR "hemicolectomy" OR "sigmoidectomy" OR "proctectomy" OR "rectosigmoidectomy" OR
"ileocecectomy" OR NEAR(ileocecal, resection, 10, FALSE) OR NEAR(ileocecal, removal, 10, FALSE) OR
"hartmann*" OR
"ileostomy" OR "colostomy" OR "anastomosis" OR "pouch construction" OR "j-pouch"') as search
join #patNotes as pt
on pt.NoteID = search.NoteID
create clustered columnstore index cci on #notesMatch;

-- Save without text
drop table if exists <SCHEMA>.matchingNotes_colectomy_NoteIDs
select PatientID, EntryDateTime, NoteID 
into <SCHEMA>.matchingNotes_colectomy_NoteIDs 
from #notesMatch
create clustered columnstore index cci on <SCHEMA>.matchingNotes_colectomy_NoteIDs;

-- Run from here down to save as CSV
-- Get reportText 
SELECT notes.PatientID, notes.EntryDateTime, notes.NoteID, notes.ReportText
from <SCHEMA>.matchingNotes_colectomy_NoteIDs as notes
join <SCHEMA>.NoteTable as notes
on notes.NoteID=notes.NoteID
-- saved as 'colectomy_notes.csv'

