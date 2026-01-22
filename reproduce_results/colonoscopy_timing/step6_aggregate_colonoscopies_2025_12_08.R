# Aggregate colonoscopies from different data sources to create a single colonoscopy table

library(VINCI)
library(DBI)
library(tidycmprsk)
library(vistime)
library(ggplot2)
library(dplyr)
library(ggrepel) # For non-overlapping text labels
library(lubridate)

# Remove vars
rm(list = ls())

source("<PATH>/Utility/R_functions/collapse_dates.R")

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = '<SERVER>')

base <-  DBI::dbGetQuery(conn, paste0("select distinct PatientID from <SCHEMA>.baseTable_with_llms"))
linkedPathAll <- DBI::dbGetQuery(conn, paste0("select * from <SCHEMA>.ibd_and_nonIBD_path_colo_results_2025_05_12"))

# Get the colonoscopy dates for all 
llm_cpt_colo <- DBI::dbGetQuery(conn, paste0("select distinct colo.PatientID, colo.llm_or_cpt_date, colo.cpt_date from 
                                              <SCHEMA>.finalPheno_colonoscopy_timing_2025_06_23 as colo
                                              join <SCHEMA>.baseTable_with_llms as base
                                              on colo.PatientID = base.PatientID"))
cpt_colo <- llm_cpt_colo[!is.na(llm_cpt_colo$cpt_date),]

# Get the colonoscopy reports which likely had no path (clean colo)
# NOTE: This is unnecessary for determining date because colonoscopy reports were filtered to be within 0-30 days of CPT or PATH. Thus, use CPT or PATH only
noPathColoReports <- DBI::dbGetQuery(conn, paste0("select distinct colo.PatientID, CAST(notes.EntryDateTime as DATE) as colonoscopyDate from <SCHEMA>.ibd_and_nonIBD_path_colo_results_2025_05_12 as colo
                                                   left join <SCHEMA>.NoteTable as notes
                                                   on TRY_CAST(colo.[NoteID.unlinked] as BIGINT) = notes.NoteID
                                                   join <SCHEMA>.baseTable_with_llms as base
                                                   on base.PatientID = colo.PatientID
                                                   where [number_of_visible_lesions.unlinked] in ('0', 'not stated')
                                                   AND ([indication.unlinked] not in ('not stated') OR [bowel_prep_quality.unlinked] not in ('not stated')
                                                      OR [landmarks_reached.unlinked] not in ('not stated'))
                                                   AND [random_biopsies_taken.unlinked] in ('no', 'not stated')
                                                   AND notes.EntryDateTime is not null"))

# All colonoscopy path reports (by specimen filtering and removing 'transrectal' prostate biopsy specimens)
pathColonoscopies <- DBI::dbGetQuery(conn, paste0("select distinct pth.PatientID, CAST(pth.SpecimenTakenDateTime as DATE) as colonoscopyDate 
  from <SCHEMA>.colonoscopyPathReports as pth
  join <SCHEMA>.baseTable_with_llms as base
  on base.PatientID = pth.PatientID
  join <SCHEMA>.Src_Pathology_SurgPathSpecimen_2024_12_26 as spec
  on spec.SurgicalPathologySID = pth.SurgicalPathologySID
  where spec.Specimen not like '%transrect%'
       AND pth.SpecimenTakenDateTime is not null"))

out.df <- data.frame()
for(id in unique(base$PatientID)){
  
  # Get tmp df's
  tmp_pathColonoscopies <- pathColonoscopies[pathColonoscopies$PatientID == id,]
  tmp_noPathColoReports <- noPathColoReports[noPathColoReports$PatientID == id,]
  tmp_cpt_colo <- cpt_colo[cpt_colo$PatientID == id,]
  tmp_llm_cpt_colo <- llm_cpt_colo[llm_cpt_colo$PatientID == id,]
  tmp_llm_monthKnown <- tmp_llm_cpt_colo[which(format(tmp_llm_cpt_colo$llm_or_cpt_date, "%m-%d") != "07-01" & is.na(tmp_llm_cpt_colo$cpt_date)),]
  tmp_llm_monthUnknown <- tmp_llm_cpt_colo[which(format(tmp_llm_cpt_colo$llm_or_cpt_date, "%m-%d") == "07-01" & is.na(tmp_llm_cpt_colo$cpt_date)),]
  
  # Get colonoscopies with associated structured VA data (CPT or documented path report)
  VA_colo <- collapse_dates(dates = c(tmp_pathColonoscopies$colonoscopyDate, tmp_cpt_colo$cpt_date), 
                            window_days = 15, keepers = tmp_pathColonoscopies$colonoscopyDate)
  
  # Get colonoscopies with either clean colonoscopy (no path generated) or with a path report
  denom_colo <- collapse_dates(dates = c(tmp_pathColonoscopies$colonoscopyDate, tmp_noPathColoReports$colonoscopyDate), 
                               window_days = 30, keepers = tmp_pathColonoscopies$colonoscopyDate)
  
  # Get all colonoscopies
  coloAll_v1 <- collapse_dates(dates = c(VA_colo, tmp_llm_monthKnown$llm_or_cpt_date), 
                               window_days = 60, keepers = VA_colo)
  coloAll <- collapse_dates(dates = c(coloAll_v1, tmp_llm_monthKnown$llm_or_cpt_date), 
                            window_days = 190, keepers = coloAll_v1)
  
  if(length(coloAll) > 0){
    for(j in 1:length(coloAll)){
      # Get current date
      thisColo <- coloAll[j]
      
      if(any(abs(tmp_pathColonoscopies$colonoscopyDate - thisColo) <= 45)){
        thisPath <- tmp_pathColonoscopies$colonoscopyDate[which(abs(tmp_pathColonoscopies$colonoscopyDate - thisColo) <= 45)]
        if(length(thisPath) > 1){
          thisPath <- thisPath[which.min(abs(thisPath - thisColo))]
        }
        source <- "pathology report"
      }else{
        thisPath <- as.Date(NA)
        source <- ""
      }
      
      if(any(abs(tmp_cpt_colo$cpt_date - thisColo) <= 45)){
        thisCPT <- tmp_cpt_colo$cpt_date[which(abs(tmp_cpt_colo$cpt_date - thisColo) <= 45)]
        if(length(thisCPT) > 1){
          thisCPT <- thisCPT[which.min(abs(thisCPT - thisColo))]
        }
        if(source == ""){
          source <- "CPT"
        }else{
          source <- "CPT and pathology report"
        }
      }else{
        thisCPT <- as.Date(NA)
        if(source == ""){
          source <- "LLMs"
        }
      }
      
      if(any(abs(denom_colo - thisColo) <= 45)){
        thisColoWithData <- denom_colo[which(abs(denom_colo - thisColo) <= 45)]
        if(length(thisColoWithData) > 1){
          thisColoWithData <- thisColoWithData[which.min(abs(thisColoWithData - thisColo))]
        }
      }else{
        thisColoWithData <- as.Date(NA)
      }
      
      if(any(abs(tmp_noPathColoReports$colonoscopyDate - thisColo) <= 45)){
        thisCleanColo <- tmp_noPathColoReports$colonoscopyDate[which(abs(tmp_noPathColoReports$colonoscopyDate - thisColo) <= 45)]
        if(length(thisCleanColo) > 1){
          thisCleanColo <- thisCleanColo[which.min(abs(thisCleanColo - thisColo))]
        }
      }else{thisCleanColo <- as.Date(NA)}
      
      out.df <- rbind(out.df, 
                      data.frame("PatientID" = id,
                                 "colonoscopyDate" = thisColo,
                                 "pathDate" = thisPath,
                                 "cptDate" = thisCPT,
                                 "completeDataDate" = thisColoWithData,
                                 "cleanColonoscopyDate" = thisCleanColo,
                                 "source" = source
                      ))
    }
  }
  
}
write.csv(out.df, paste0("<PATH>/finalPhenotypes/results/aggregated_colonoscopy_sources_", Sys.Date(), ".csv"), row.names=F)
# Write to SQL
DBI::dbWriteTable(conn, "finalPheno_colonoscopy_timing_2025_12_08", out.df, overwrite=T)

