use <DATABASE>;

-- NOT FUNCTIONAL CODE

-- Filter by baseTable to only get patients with at least 1 IBD ICD code
drop table if exists #patSID;
select PatientSID, base.* into #patSID from Src.CohortCrosswalk as coh 
join <schema>.baseTable as base
on coh.PatientICN = base.PatientICN
where base.IBDDxDateICD is not null;
create clustered columnstore index cci on #patSID;
-- 496,866 rows affected. 169,443 unique patients

-- Included ICD codes used to make baseTable are:
-- ICD-9: 555.1*, 555.2*, and 556.*
-- ICD-10: K50.1*, K50.8*, K51.* (excluding K51.4*), and K52.3*
-- where '*' represents a wildcard and can be any number or nothing. For example, 5.1* matches 5.1, 5.12, 5.190, and 5.110918

-- Select all note SIDs for patient(s). Doing this ahead of time will speed up the text search.
drop table if exists #patTIU;
Select tiu.NoteID, tiu.EntryDateTime, #patSID.*
into #patTIU
From NotesTable as tiu
join #patSID 
	on #patSID.PatientSID = tiu.PatientSID
create clustered columnstore index cci on #patTIU;
-- 192,732,534 rows affected

-- Cut down to notes that match
-- This uses Microsoft SQL Server's Full-text Search function.
drop table if exists #notesMatch;
select pt.*
into #notesMatch
from tvf_FullTextSearch('"crohn*" OR NEAR(ulcerative, colitis, 10, TRUE) OR NEAR(ulcerative, proctocolitis, 10, TRUE) 
OR NEAR(ulcerative, proctitis, 10, TRUE) OR
"uc" OR "u.c." OR "cuc" OR "c.u.c." OR 
"inflammatory bowel disease" OR "ibd" OR NEAR(chronic, colitis, 10, FALSE) OR NEAR(chronic, proctitis, 10, FALSE) OR 
NEAR(chronic, proctocolitis, 10, FALSE) OR NEAR(colonoscopy, findings, 10, FALSE)') as search
join #patTIU as pt
on pt.NoteID = search.NoteID
create clustered columnstore index cci on #notesMatch;
-- 6,635,399 rows affected. (This tmp table saved as <schema>.matchingNotes_ibd_type_TIUDocSIDs below)

-- Save without text
--drop table if exists <schema>.matchingNotes_ibd_type_TIUDocSIDs
select PatientICN, EntryDateTime, NoteID 
into <schema>.matchingNotes_ibd_type_TIUDocSIDs 
from #notesMatch
create clustered columnstore index cci on <schema>.matchingNotes_ibd_type_TIUDocSIDs;
-- 6,635,399 rows affected.

-- Break into 3 groups and run each one at a time. Otherwise, tables are too large.
-- Get reportText for a single group (3 of 3) and save as a csv
WITH groupNotes AS (
	select notes.PatientICN, notes.EntryDateTime, notes.NoteID
	from <schema>.matchingNotes_ibd_type_TIUDocSIDs as notes
	join <schema>.baseTable4_1plus_ICD_withGroups as base
	on base.PatientICN = notes.PatientICN
	where base.GroupNumber=3
)
SELECT groupNotes.PatientICN, groupNotes.EntryDateTime, groupNotes.NoteID, tiu.ReportText
from groupNotes
join NotesTable as tiu
on tiu.NoteID=groupNotes.NoteID




