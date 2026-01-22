use <DATABASE>;

-- Filter by baseTable to only get patients with IBD
drop table if exists #patID;
select PatientID, base.* into #patID from <SCHEMA>.Cohort as coh 
join <SCHEMA>.baseTable_with_llms as base
on coh.PatientID = base.PatientID
create clustered columnstore index cci on #patID;

-- Select all note SIDs for patient(s). Doing this ahead of time will speed up the text search.
drop table if exists #patTIU;
Select notes.NoteID, notes.EntryDateTime, #patID.*
into #patTIU
From <SCHEMA>.NoteTable as notes
join #patID 
	on #patID.PatientID = notes.PatientID
create clustered columnstore index cci on #patTIU;

-- Cut down to notes that match
drop table if exists #notesMatch;
select pt.*
into #notesMatch
from <SCHEMA>.FullTextSearch('"colonoscopy"') as search
join #patTIU as pt
on pt.NoteID = search.NoteID
create clustered columnstore index cci on #notesMatch;

-- Save without text
drop table if exists <SCHEMA>.matchingNotes_colonoscopy_NoteIDs
select PatientID, EntryDateTime, NoteID 
into <SCHEMA>.matchingNotes_colonoscopy_NoteIDs 
from #notesMatch
create clustered columnstore index cci on <SCHEMA>.matchingNotes_colonoscopy_NoteIDs;

-- Run from here down to save as CSV
-- Get reportText 
SELECT notes.PatientID, notes.EntryDateTime, notes.NoteID, notes.ReportText
from <SCHEMA>.matchingNotes_colonoscopy_NoteIDs as notes
join <SCHEMA>.NoteTable as notes
on notes.NoteID=notes.NoteID

