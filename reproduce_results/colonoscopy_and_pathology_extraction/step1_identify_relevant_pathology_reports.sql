Use <DATABASE>

/* ----------------------- Identify colonoscopy pathology reports using the 'Specimen' field ------------------------*/
SELECT 
Tspec.Specimen,
Tspec.PatientID,
Tspec.PathologyReportID,
Tspec.SpecimenTakenDateTime
INTO #Specimen_table
FROM Pathology_Specimen_Table Tspec
where specimen like '%colon%' OR Specimen LIKE '%rectum%' or Specimen LIKE '%colorectal%' or Specimen LIKE '%rectal%'
or Specimen LIKE  '%cecum%' or Specimen LIKE '%hepatic flexure%' or Specimen LIKE '%ileocecal valve%'
or Specimen LIKE '%sigmoid%' or Specimen LIKE '%caecum%' or Specimen like '%large intest%'
or Specimen LIKE '%splenic flexure%'

select spec.PathologyReportID, spec.SpecimenTakenDateTime, coh.PatientICN into <SCHEMA>.Src_Pathology_specimenFiltered_colonoscopyPathReports
from #Specimen_table as spec
join Cohort as coh
on coh.PatientID=spec.PatientID
create clustered columnstore index cci on <SCHEMA>.Src_Pathology_specimenFiltered_colonoscopyPathReports


/*-------------------- Find pathology reports with dysplasia terms in the 'MicroscopicExam' OR 'Diagnosis' sections ------------------*/
DROP TABLE if exists #Microscopic_table
SELECT 
Micro.SpecimenTakenDateTime,
Micro.PatientID,
Micro.MicroscopicDescription,
Micro.PathologyReportID
INTO #Microscopic_table
FROM <SCHEMA>.Pathology_MicroscopicExam_Table Micro
WHERE MicroscopicDescription like '%dysplas%' OR MicroscopicDescription like '%lgd%' OR
MicroscopicDescription like '%low grade%' OR MicroscopicDescription like '%low-grade%'
OR MicroscopicDescription like '%dalm%' OR MicroscopicDescription like '%adenoma%' OR
MicroscopicDescription like '%invasi%' OR MicroscopicDescription like '%tumor%' OR MicroscopicDescription like '%carcinoma%' OR
MicroscopicDescription like '%high grade%' OR MicroscopicDescription like '%hgd%' OR MicroscopicDescription like '%high-grade%' 
OR MicroscopicDescription like '%in-situ%' OR MicroscopicDescription like '%in situ%' OR MicroscopicDescription like '%intramucosal%'

DROP TABLE if exists #Diagnosis_table
SELECT 
Dx.SpecimenTakenDateTime,
Dx.PatientID,
Dx.SurgicalPathologyDiagnosis,
Dx.PathologyReportID
INTO #Diagnosis_table
FROM <SCHEMA>.Pathology_Diagnosis_Table Dx
WHERE SurgicalPathologyDiagnosis like '%dysplas%' OR SurgicalPathologyDiagnosis like '%lgd%' OR
SurgicalPathologyDiagnosis like '%low grade%' OR SurgicalPathologyDiagnosis like '%low-grade%'
OR SurgicalPathologyDiagnosis like '%dalm%' OR SurgicalPathologyDiagnosis like '%adenoma%' OR
SurgicalPathologyDiagnosis like '%invasi%' OR SurgicalPathologyDiagnosis like '%tumor%' OR SurgicalPathologyDiagnosis like '%carcinoma%' OR
SurgicalPathologyDiagnosis like '%high grade%' OR SurgicalPathologyDiagnosis like '%hgd%' OR SurgicalPathologyDiagnosis like '%high-grade%' 
OR SurgicalPathologyDiagnosis like '%in-situ%' OR SurgicalPathologyDiagnosis like '%in situ%' OR SurgicalPathologyDiagnosis like '%intramucosal%'

-- Join the Microscopic exam and diagnosis tables
drop table if exists #Dx_Mx
select Coalesce(Dx.PathologyReportID, Mx.PathologyReportID) as PathologyReportID,
Coalesce(Dx.SpecimenTakenDateTime, Mx.SpecimenTakenDateTime) as SpecimenTakenDateTime,
Coalesce(Dx.PatientID, Mx.PatientID) as PatientID,
Dx.SurgicalPathologyDiagnosis, Mx.MicroscopicDescription
into #Dx_Mx
from #Diagnosis_table Dx
full join #Microscopic_table Mx
on Dx.PathologyReportID = Mx.PathologyReportID

/*--------------------------------------- SAVE TABLE ----------------------------------------------*/
DROP TABLE if exists <SCHEMA>.path_dys_terms_positive_ALL_2024_12_26
SELECT DISTINCT
T1.PatientID,
T1.Specimen,
T1.SpecimenTakenDateTime,
T2.MicroscopicDescription,
T2.SurgicalPathologyDiagnosis,
T2.PathologyReportID
INTO <SCHEMA>.path_dys_terms_positive_ALL_2024_12_26
FROM #Specimen_table T1 
JOIN  #Dx_Mx T2
ON T1.PatientID = T2.PatientID AND T1.PathologyReportID = T2.PathologyReportID
join Cohort T3
on T1.PatientID = T3.PatientID

CREATE CLUSTERED COLUMNSTORE INDEX CCI ON <SCHEMA>.path_dys_terms_positive_ALL_2024_12_26


