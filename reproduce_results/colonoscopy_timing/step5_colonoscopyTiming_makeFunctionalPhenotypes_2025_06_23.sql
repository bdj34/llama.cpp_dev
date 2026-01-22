use <DATABASE>;

-- Matched cohort
drop table if exists #cohort
select t1.* into #cohort
from 
(select PatientID, IBDC from <SCHEMA>.baseTable_with_llms
UNION ALL
select PatientID, 0 as IBDC from <SCHEMA>.baseTable_nonIBD_matched) as t1; 

-- Get CPT colonoscopies
drop table if exists #cptOnly
select cpt.PatientID, CAST(cpt.ProcDate as DATE) as cpt_date 
into #cptOnly
from <SCHEMA>.colonoscopy_CPT_allPts_2025_01_13 cpt
join #cohort 
on #cohort.PatientID = cpt.PatientID

-- Add CPT colonoscopies to the LLM colonoscopies
drop table if exists #llm
select llm.*, CAST(cpt_date as DATE) as llm_or_cpt_date
into #llm
from 
(select * from <SCHEMA>.results_ibd_colonoscopy_timing_2025_04_23
UNION ALL
select * from <SCHEMA>.results_nonIBD_colonoscopy_timing_2025_04_23) as llm
join #cohort as coh
on llm.PatientID = coh.PatientID

-- Use LLM date when CPT date is null
UPDATE #llm
SET llm_or_cpt_date = CAST(llm_date as DATE)
	WHERE cpt_date is null

-- Outer join to combine additional unique colonoscopies from CPT only
drop table if exists #combined
select distinct coalesce(A.PatientID, B.PatientID) as PatientID, COALESCE(A.llm_or_cpt_date, B.cpt_date) as llm_or_cpt_date,
A.ColonoscopyYN, A.Site, A.Month, A.Year, A.llm, A.llm_date, Coalesce(A.cpt_date, B.cpt_date) as cpt_date, A.supporting_evidence
into #combined
FROM #llm as A
FULL OUTER JOIN #cptOnly as B
on A.PatientID = B.PatientID AND A.llm_or_cpt_date = B.cpt_date


-- Save table
drop table if exists <SCHEMA>.finalPheno_colonoscopy_timing_2025_06_23
select combined.*, coh.IBDC into <SCHEMA>.finalPheno_colonoscopy_timing_2025_06_23
from #combined as combined
join #cohort as coh on coh.PatientID = combined.PatientID
create clustered columnstore index cci on <SCHEMA>.finalPheno_colonoscopy_timing_2025_06_23

