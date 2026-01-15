use ORD_Curtius_202210036D;

-- Get TIU docs with the right doc definition
-- Then ensure that these TIU docs are:
-- referring to IBD pts from baseTable5_llms_2025_01_28 (yes this has all 81,266)
-- 0-30 days after CPT code or pathDomain entry for colonoscopy

-- Cohort from here:
-- <SCHEMA>.baseTable_with_llms

-- Pull path reports from here:
-- <SCHEMA>.Src_Pathology_specimenFiltered_colonoscopyPathReports

-- CPT from here:
-- <SCHEMA>.colonoscopy_CPT_allPts_2025_01_13

-- TIU docs from Samir's group by document definition from here:
-- <SCHEMA>.COLONOSCOPY_2025_04_02

-- Get PatientID for patients with IBD
drop table if exists #patSID;
select PatientID, base.* into #patSID from <SCHEMA>.CohortCrosswalk as coh 
join <SCHEMA>.baseTable_with_llms as base
on coh.PatientID = base.PatientID
create clustered columnstore index cci on #patSID;

-- Cut down to Gupta team notes that are for IBD pts
drop table if exists #coloNotesDocDef
select distinct T1.NoteID, T2.PatientID into #coloNotesDocDef
from <SCHEMA>.COLONOSCOPY_2025_04_02 as T1
join #patSID as T2
on T1.PatientID = T2.PatientID
create clustered columnstore index cci on #coloNotesDocDef

-- Add Entry Datetime and Reference date time
drop table if exists #coloNotesAll
select distinct docdef.*, notes.EntryDateTime, notes.ReferenceDateTime into #coloNotesAll 
from #coloNotesDocDef as docdef
join <SCHEMA>.NoteTable as notes
on notes.NoteID = docdef.NoteID
create clustered columnstore index cci on #coloNotesAll

-- Date restriction from CPT or path
drop table if exists #coloNotesDated
select distinct colo.*, cpt.ProcDate, pth.SpecimenTakenDateTime, pth.SurgicalPathologySID 
into #coloNotesDated
from #coloNotesAll as colo
left join <SCHEMA>.colonoscopy_CPT_allPts_2025_01_13 as cpt
on cpt.PatientID = colo.PatientID
left join <SCHEMA>.Src_Pathology_specimenFiltered_colonoscopyPathReports as pth
on pth.PatientID = colo.PatientID
where (DATEDIFF(DAY, pth.SpecimenTakenDateTime, colo.ReferenceDateTime) <= 30
	AND DATEDIFF(DAY, pth.SpecimenTakenDateTime, colo.ReferenceDateTime) >= 0)
OR (DATEDIFF(DAY, pth.SpecimenTakenDateTime, colo.EntryDateTime) <= 30
	AND DATEDIFF(DAY, pth.SpecimenTakenDateTime, colo.EntryDateTime) >= 0) 
OR (DATEDIFF(DAY, cpt.ProcDate, colo.ReferenceDateTime) <= 30
	AND DATEDIFF(DAY, cpt.ProcDate, colo.ReferenceDateTime) >= 0)
OR (DATEDIFF(DAY, cpt.ProcDate, colo.EntryDateTime) <= 30
	AND DATEDIFF(DAY, cpt.ProcDate, colo.EntryDateTime) >= 0)
AND (colo.EntryDateTime is not null OR colo.ReferenceDateTime is not null)
AND (cpt.ProcDate is not null OR pth.SpecimenTakenDateTime is not null)
GROUP BY NoteID
create clustered columnstore index cci on #coloNotesDated

-- Terms restriction
drop table if exists #coloNotesFinal
select distinct colo.* into #coloNotesFinal
from #coloNotesDated as colo
join <SCHEMA>.NoteTable as notes
on colo.NoteID = notes.NoteID
where (notes.ReportText like '%colonoscopy%'
	OR notes.ReportText like '%procedure%'
	OR notes.ReportText like '%scope%'
	OR notes.ReportText like '%bowel%prep%'
	OR notes.ReportText like '%indication%'
	OR notes.ReportText like '%insert%'
	OR notes.ReportText like '%withdraw%')
AND (notes.ReportText like '%cecum%'
	OR notes.ReportText like '%ileum%'
	OR notes.ReportText like '%ileocecal%'
	OR notes.ReportText like '%sigmoid%'
	OR notes.ReportText like '%rectum%'
	OR notes.ReportText like '%ascending%'
	OR notes.ReportText like '%transverse%'
	OR notes.ReportText like '%descending%'
	OR notes.ReportText like '%flexure%'
	OR notes.ReportText like '%cm%')
create clustered columnstore index cci on #coloNotesFinal

-- Save as permanent table
select * into <SCHEMA>.putative_ibd_coloReports_2025_04_02
from #coloNotesFinal
create clustered columnstore index cci on <SCHEMA>.putative_ibd_coloReports_2025_04_02

-- Save as csv and process in python
select distinct coh.PatientID, coh.EntryDateTime, coh.NoteID, notes.ReportText
from <SCHEMA>.putative_ibd_coloReports_2025_04_02 as coh 
join <SCHEMA>.NoteTable as notes
on coh.NoteID = notes.NoteID
-- CSV name: "colonoscopyReports.csv"

