use <DATABASE>;

-- Select all note IDs for relevant patients. 
-- Doing this ahead of time will speed up the text search.
Select notes.NoteID, notes.EntryDateTime, base.*
into #patNotes
From <SCHEMA>.NoteTable as notes
join <SCHEMA>.baseTable_with_llms as base
	on base.PatientID = notes.PatientID
create clustered columnstore index cci on #patNotes;

-- Cut down to notes that match (same as ibd type but without "colonosc* findings")
drop table if exists #notesMatch;
select pt.*
into #notesMatch
from <SCHEMA>.FullTextSearch('"crohn*" OR NEAR(ulcerative, colitis, 10, TRUE) 
OR NEAR(ulcerative, proctocolitis, 10, TRUE) 
OR NEAR(ulcerative, proctitis, 10, TRUE) OR
"uc" OR "u.c." OR "cuc" OR "c.u.c." OR 
"inflammatory bowel disease" OR "ibd" OR NEAR(chronic, colitis, 10, FALSE) OR NEAR(chronic, proctitis, 10, FALSE) OR 
NEAR(chronic, proctocolitis, 10, FALSE)') as search
join #patNotes as pt
on pt.NoteID = search.NoteID
create clustered columnstore index cci on #notesMatch;

-- Save without text
select PatientID, EntryDateTime, NoteID 
into <SCHEMA>.matchingNotes_ibd_year_NoteIDs 
from #notesMatch
create clustered columnstore index cci on <SCHEMA>.matchingNotes_ibd_year_NoteIDs;

-- Get reportText with SIDs and save to csv
SELECT notes.PatientID, notes.EntryDateTime, notes.NoteID, notes.ReportText
from <SCHEMA>.matchingNotes_ibd_year_NoteIDs as matching
join <SCHEMA>.NoteTable as notes
on notes.NoteID=matching.NoteID
-- Saved as: 'ibdYear_notes.csv'