use <DATABASE>

-- Get NoteID
drop table if exists #withTIU
select path2Notes.NoteID, dys.SurgicalPathologySID, dys.PatientID, path2Notes.PatientSID, path2Notes.Sta3n
into #withTIU
from <SCHEMA>.path_dys_terms_positive_ALL_2024_12_26 as dys
left join <SCHEMA>.<table_linking_pathology_to_full_notes> as path2Notes
on dys.SurgicalPathologySID = path2Notes.SurgicalPathologySID
create clustered columnstore index cci on #withTIU;

-- Pull corresponding full note and save
--drop table if exists <SCHEMA>.ibd_fullPathReports_dysplasiaPlus_2025_01_31
select notes.ReportText, path2Notes.*, notes.EntryDateTime
into <SCHEMA>.ibd_fullPathReports_dysplasiaPlus_2025_01_31
from <SCHEMA>.NoteTable as notes
join #withTIU as path2Notes
on path2Notes.NoteID = notes.NoteID
join <SCHEMA>.baseTable_llm_diagnosis as base
on base.PatientID = path2Notes.PatientID
where ReportText is not null
create clustered columnstore index cci on <SCHEMA>.ibd_fullPathReports_dysplasiaPlus_2025_01_31;

-- Get the path domain entries that don't have a corresponding full note
drop table if exists #missingFullText
select path2Notes.* 
into #missingFullText
from #withTIU as path2Notes 
join <SCHEMA>.baseTable_llm_diagnosis as base
on base.PatientID = path2Notes.PatientID
where NoteID is null

-- Add Specimen, Gross Description, Microscopic Description, Diagnosis sections for missing full note
drop table if exists <SCHEMA>.ibd_missing_fullPathReports_2025_31_01
select missing.*, specimen.Specimen, gross.GrossDescription, micro.MicroscopicDescription, diagnosis.SurgicalPathologyDiagnosis, specimen.SpecimenTakenDateTime
into <SCHEMA>.ibd_missing_fullPathReports_2025_31_01
from #missingFullText as missing
join <SCHEMA>.Pathology_SurgPathSpecimen as specimen
on specimen.SurgicalPathologySID = missing.SurgicalPathologySID
join <SCHEMA>.Pathology_SurgPathDiagnosis as diagnosis
on diagnosis.SurgicalPathologySID = missing.SurgicalPathologySID
join <SCHEMA>.Pathology_SurgPathGrossDescription as gross
on gross.SurgicalPathologySID = missing.SurgicalPathologySID
join <SCHEMA>.Pathology_SurgPathMicroscopicExam as micro
on micro.SurgicalPathologySID = missing.SurgicalPathologySID
create clustered columnstore index cci on <SCHEMA>.ibd_missing_fullPathReports_2025_31_01

