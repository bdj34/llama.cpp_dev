use <DATABASE>;

-- Select all note IDs for our cohort.
-- Doing this ahead of time will speed up the text search.
drop table if exists #patNotes;
Select notes.NoteID, notes.EntryDateTime, coh.*
into #patNotes
From <SCHEMA>.NoteTable as notes
join <SCHEMA>.baseTable_with_llms as coh
	on coh.PatientID = notes.PatientID
create clustered columnstore index cci on #patNotes;

-- Cut down to notes that match
drop table if exists #notesMatch;
select pt.*
into #notesMatch
from <SCHEMA>.FullTextSearch('("colorectal cancer" OR "rectal cancer" OR "colon cancer"
OR "crc") AND NOT ("cancer surveillance" OR "crc surveillance" OR "cancer screening" OR "crc screening")') as search
join #patNotes as pt
on pt.NoteID = search.NoteID
create clustered columnstore index cci on #notesMatch;
-- Do further negation in python

-- Save without text
drop table if exists <SCHEMA>.matchingNotes_CRC_noteIDs
select PatientID, EntryDateTime, NoteID 
into <SCHEMA>.matchingNotes_CRC_noteIDs 
from #notesMatch
create clustered columnstore index cci on <SCHEMA>.matchingNotes_CRC_noteIDs;

-- Run from here down to save as CSV
SELECT notes.PatientID, notes.EntryDateTime, notes.NoteID, notes.ReportText
from <SCHEMA>.matchingNotes_CRC_noteIDs as matching
join <SCHEMA>.NoteTable as notes
on matching.NoteID=notes.NoteID

-- Saved as 'crc_notes.csv'
