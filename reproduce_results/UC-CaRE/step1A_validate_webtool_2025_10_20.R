# Implement Curtius et al Gut 2022 webtool paper clinical risk stratification
# Use fns defined in <PATH>/webtool_validation/fns/UCCARE_fns.R
library(VINCI)
library(DBI)
library(ggplot2)
library(tidycmprsk)
library(survival)
library(ggsurvfit)
library(survminer)
library(naniar)
library(eulerr)
library(gtsummary)
library(gt)
library(labelled)
library(patchwork)

# Remove vars
rm(list = ls())

source("<PATH>/webtool_validation/fns/UCCARE_fns.R")

setwd("<PATH>/webtool_validation")

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = '<SERVER>')

# Pull cohort
base <-  DBI::dbGetQuery(conn, paste0('select * from <SCHEMA>.baseTable_with_llms'))
uc <- base[base$diagnosis %in% c("Ulcerative colitis", "Ulcerative proctitis"),]

# To determine reason for exclusion, find the pts without any colo path reports in path domain
noPath_ptsAll <- DBI::dbGetQuery(conn, paste0('select distinct base.PatientID from <SCHEMA>.baseTable_with_llms as base 
                                      left join <SCHEMA>.colonoscopyPathReports as colo
                                              on colo.PatientID = base.PatientID 
                                              where colo.PatientID is null'))
noPath_pts <- noPath_ptsAll$PatientID[noPath_ptsAll$PatientID %in% uc$PatientID]

# Targeted completeness of resection run using medGemma-27B
completenessOfResection <- read.csv(paste0("<PATH>/nlp_v2/IBD_dx/completenessOfResection/",
                                           "results/aggregated_completeness_medGemma_27B_2025-09-29.csv"))

# Get all PSC ICD codes
pscAll <- DBI::dbGetQuery(conn, paste0('select * from <SCHEMA>.PSC_ICD_code_table'))
psc.df <- pscAll[pscAll$PatientID %in% uc$PatientID,]

# Get smoking status at index (need to re-generate this if index date changes)
smoking <- DBI::dbGetQuery(conn, paste0('select * from <SCHEMA>.UCCARE_Smoking'))

# Get colectomy data
colectomy <- DBI::dbGetQuery(conn, paste0("select * from <SCHEMA>.finalPheno_firstColectomy_2025_06_24
                                          where IBDC = 1"))

# See <PATH>/finalPhenotypes/colectomy-aware_HGDCRC_and_CRC_forSQL_2025_09_05.R
# for HGD/CRC and invasive CRC table creation taking colectomy into account
hgd_crcAll <- DBI::dbGetQuery(conn, paste0("select * from <SCHEMA>.colectomy_aware_hgd_crc_2025_09_05"))
hgd_crc <- hgd_crcAll[hgd_crcAll$PatientID %in% uc$PatientID,]

crcAll <- DBI::dbGetQuery(conn, paste0("select * from <SCHEMA>.colectomy_aware_crc_2025_09_05"))
crc <- crcAll[crcAll$PatientID %in% uc$PatientID,]

# Get linked colonoscopy and pathology extraction
linked_pathAll <- DBI::dbGetQuery(conn, paste0("select * from <SCHEMA>.ibd_and_nonIBD_path_colo_results_2025_05_12"))
linked_path <- linked_pathAll[linked_pathAll$PatientID %in% uc$PatientID,]

# Pull finalized colonoscopy timing which accounts for the source of the data and already has collapsed dates
colonoscopy <- DBI::dbGetQuery(conn, paste0("select * from <SCHEMA>.finalPheno_colonoscopy_timing_2025_09_09
                                            where IBDC=1"))

# Order the completeness so that we pick up the most "bad" one (worst last)
# (e.g., incomplete is picked up when both incomplete and complete are present)
originalCompleteness_ordered <- c("complete", "piecemeal", "not stated", "unknown", "incomplete")
targetedCompleteness_ordered <- c("R0", "Insufficient information", "Uncertain", "R1", "R2")
locations_ordered <- c("rectum", "rectosigmoid", "sigmoid", "descending", "splenic flexure",
                       "transverse", "hepatic flexure", "ascending", "cecum", "ileocecal valve")

# Identify LGD patients
lgds <- return_only_lgd(linked_path)
potential_pts <- unique(lgds$PatientID)

# Initialize include and exclude dfs
include_ptsRaw <- data.frame()
exclude.df <- data.frame("PatientID" = character(),
                         "Reason" = character())

# Loop through patients
for(id in potential_pts){
  
  # Get pt specific df's
  pt <- linked_path[linked_path$PatientID == id,]
  hgd_crc_pt <- hgd_crc[hgd_crc$PatientID == id,]
  crc_pt <- crc[crc$PatientID == id,]
  col_pt <- colectomy[colectomy$PatientID == id,]
  ptColonoscopy <- colonoscopy[colonoscopy$PatientID == id,]
  ibd_type <- "Ulcerative colitis (including proctitis)"
  
  # Get smoking status
  smkStatus <- smoking$SMK[smoking$PatientID == id]
  if(length(smkStatus) == 0){
    smkStatus <- 0
  }
  
  # Reset includeFlag for this pt
  includeFlag <- F
  
  # Get path specific data. This is data extracted only from pathology reports
  path_pt <- pt[!is.na(pt$PathologyReportID),]
  lgd <- return_only_lgd(path_pt)
  uniq_dates <- sort(unique(lgd$SpecimenTakenDateTime)) # we are looking for the first colitis-associated LGD
  
  # Go through unique path reports
  for(j in 1:length(uniq_dates)){
    
    # If we already have a reason to exclude this patient, don't need to redo analysis
    if(id %in% exclude.df$PatientID){break}
    
    # Get LGDs
    path <- path_pt[path_pt$SpecimenTakenDateTime==uniq_dates[j],]
    index_path <- return_only_lgd(path)
    
    # If we don't have any linked info, exclude patient
    if(all(is.na(index_path$sample_ID.linked))){
      exclude.df <- rbind(exclude.df, data.frame("PatientID" = id, "Reason" = "No linked colonoscopy report"))
      break
    }
    
    # Get the path/colo reports from various time windows around the index LGD
    time_diff_colo <- as.numeric(difftime(as.Date(pt$EntryDateTime.unlinked), as.Date(uniq_dates[j]), 
                                          units="days")/365.25)
    time_diff_path <- as.numeric(difftime(as.Date(pt$SpecimenTakenDateTime), as.Date(uniq_dates[j]), 
                                          units="days")/365.25)
    
    pastFive <- pt[which((time_diff_colo >= -5 & time_diff_colo <= 30/365.25) |
                           (time_diff_path <= 0 &
                              time_diff_path >= -5)),]
    
    now <- pt[which((time_diff_colo >= -30/365.25 & time_diff_colo <= 30/365.25) |
                      (time_diff_path <= 0 &
                         time_diff_path >= -30/365.25)),]
    
    nextFive_excludeNow <- pt[which((time_diff_colo <= 5 & time_diff_colo >= 60/365.25) |
                                      (time_diff_path >= 30/365.25 &
                                         time_diff_path <= 5)),]
    future_path <- pt[which(time_diff_path >= 30/365.25),]
    
    past_excludeNow <- pt[which((time_diff_colo <= -30/365.25) |
                                  (time_diff_path <= -30/365.25 &
                                     time_diff_path >= -5)),]
    
    nowOrPast <- pt[which(time_diff_colo <= 30/365.25 | time_diff_path <= 0),]
    
    # Determine if the patient had a prior dx indefinite for dysplasia
    previousIND <- ind_binary(past_excludeNow)
    
    # Get the number of previous colonoscopies, differentiating between those where we
	# have data (VA path/colonoscopy reports, CPT) vs. those we don't (external picked up by LLM from general notes)
    num_previous_colo_withData <- length(ptColonoscopy$completeDataDate[which(as.Date(ptColonoscopy$completeDataDate) <
                                                                          (as.Date(uniq_dates[j]) - 10) & 
                                                                          !is.na(ptColonoscopy$completeDataDate))])
    num_previous_colo <- length(ptColonoscopy$colonoscopyDate[which(as.Date(ptColonoscopy$colonoscopyDate) <
                                                                                (as.Date(uniq_dates[j]) - 10) & 
                                                                                !is.na(ptColonoscopy$colonoscopyDate))])
    
    # Exclude if previous or concurrent HGD/CRC (any source)
    if(nrow(hgd_crc_pt[!is.na(hgd_crc_pt$first_hgd_crc_dx_date),]) > 0){
      if(hgd_crc_pt$first_hgd_crc_dx_date <= as.Date(uniq_dates[j])){
        exclude.df <- rbind(exclude.df, data.frame("PatientID" = id, "Reason" = "Previous or concurrent advanced lesion"))
        break
      }
    }
    
    # Exclude if colectomy by CPT before or less than 5 days after index
    if(nrow(col_pt[!is.na(col_pt$cpt_date),]) > 0){
      if(difftime(as.Date(uniq_dates[j]), 
                  min(as.Date(col_pt$colectomyDate_llm_cpt[!is.na(col_pt$cpt_date)]), na.rm=T), 
                  units="days") >= -5){
        exclude.df <- rbind(exclude.df, data.frame("PatientID" = id, "Reason" = "Previous colectomy (prior to or within 5 days, by CPT, of index LGD)"))
        break
      } 
    }
    
    # Exclude if colectomy by LLM before/near index (time window varies)
    if(nrow(col_pt[is.na(col_pt$cpt_date),]) > 0){
      llmColectomy <- col_pt[is.na(col_pt$cpt_date),]
      first_llm_colectomy <- llmColectomy[order(llmColectomy$colectomyDate_llm_cpt)[1],]
      
      # If year is before, always exclude
      if(as.numeric(first_llm_colectomy$llm_Year) < as.numeric(format(as.Date(uniq_dates[j]), "%Y"))){
        exclude.df <- rbind(exclude.df, data.frame("PatientID" = id, "Reason" = "Previous colectomy (prior to index LGD year, by LLM)"))
        break
      }
      
      # If year is same and month is unknown, exclude
      if(as.numeric(first_llm_colectomy$llm_Year) == as.numeric(format(as.Date(uniq_dates[j]), "%Y")) &
          first_llm_colectomy$llm_Month == "unknown"){
        exclude.df <- rbind(exclude.df, data.frame("PatientID" = id, "Reason" = "Previous colectomy (same year as index, month unknown by LLM)"))
        break
      }
      
      # If month is known and year is the same, exclude if month is same or before index
      if(first_llm_colectomy$llm_Month != "unknown"){
        if(as.numeric(first_llm_colectomy$llm_Year) == as.numeric(format(as.Date(uniq_dates[j]), "%Y"))){
          if(which(month.name %in% first_llm_colectomy$llm_Month) <= as.numeric(format(as.Date(uniq_dates[j]), "%m"))){
            exclude.df <- rbind(exclude.df, data.frame("PatientID" = id, "Reason" = "Previous colectomy (same year as index LGD and same or earlier month, by LLM)"))
            break
          }
        }
      } 
    }
    
    # Determine the max known extent of the colitis and whether any LGD within colitis extent
    colitis_list <- return_colitis_associated(index_path, nowOrPast)
    indexLGD <- colitis_list[[1]]
    max_extent <- colitis_list[[2]]
    if(nrow(indexLGD)==0){
      colitis_associated <- 0
      if(j == length(uniq_dates)){
        exclude.df <- rbind(exclude.df, data.frame("PatientID" = id, "Reason" = "No LGD within colitis extent"))
      }
      next # Consider next timepoint if another LGD.
    }else{
      colitis_associated <- 1
    }
    
    # If we don't have any linked info, exclude patient
    if(all(is.na(indexLGD$sample_ID.linked))){
      exclude.df <- rbind(exclude.df, data.frame("PatientID" = id, "Reason" = "No linked colonoscopy report (v2)"))
      break
    }else{
      indexLGD <- indexLGD[!is.na(indexLGD$sample_ID.linked),]
    }
    
    # See if "any_invisible" (random bx) and get morphology (UCCaRE fns)
    any_invisible <- any_is_invisible(indexLGD)
    index_morphology <- get_morphology(indexLGD)
    
    # See if incompletely resected (original method). Ordered so most incomplete is the one used
    completenessOriginal <- tail(originalCompleteness_ordered[originalCompleteness_ordered %in%
                                                                indexLGD$completeness_of_resection.linked], 1)
    # Get the specimen type
    spec_type <- get_spec_type(indexLGD)
    
    # Check if multifocal. Require both to be colitis-associated.
    multifocal <- is_multifocal(indexLGD)
    
    # Get the size and see if >= 1cm
    size_list <- get_sizes(indexLGD)
    large <- size_list[[1]] # 1cm threshold. Binary
    sizes <- size_list[[2]] # Sizes in cm
    
    # Histological inflammation from the index lesion
    histo_infl <- as.numeric(any(indexLGD$inflammation_severity.path %in% c("moderate", "severe")))
    
    # Endoscopic inflammation from now only
    endo_infl_list <- get_endo(now)
    endo_infl <- endo_infl_list[[1]]
    max_endo_now <- endo_infl_list[[2]]
    max_endo_nextFive <- endo_nextFive(nextFive_excludeNow)
    
    # Endoscopic inflammation from past five
    endo_infl_list_past5 <- get_endo(pastFive)
    endo_infl_past5 <- endo_infl_list_past5[[1]]
    max_endo_past5 <- endo_infl_list_past5[[2]]
    
    # Colonoscopy quality
    quality_ordered <- c("inadequate", "poor", "fair", "good", "excellent")
    bowel_prep_quality <- suppressWarnings(min(which(quality_ordered %in% now$bowel_prep_quality.unlinked)))
    if(bowel_prep_quality == Inf){
      bowel_prep_quality <- NA
    }
    
    # Colonoscopy landmarks reached
    landmarks_ordered <- c("rectum", "rectosigmoid junction", "sigmoid colon", "descending colon",
                           "splenic flexure", "transverse colon", "hepatic flexure", "ascending colon",
                           "cecum", "ileocecal valve", "ileum", "terminal ileum")
    landmark_reached <- suppressWarnings(min(9, max(0, max(which(landmarks_ordered %in% now$landmarks_reached.unlinked)))))
    if(landmark_reached == 0){
      landmark_reached <- NA
    }
    
    # Get dates/locations/sources of advanced neoplasia and CRC
    if(nrow(hgd_crc_pt) != 0){
      advNeo_date_note <- hgd_crc_pt$note
      advNeo_date_source <- hgd_crc_pt$date_source
      advNeo_date <- hgd_crc_pt$first_hgd_crc_dx_date
      advNeo_location <- hgd_crc_pt$location
      advNeo_location_same_as_LGD <- as.numeric(any(unlist(strsplit(hgd_crc_pt$location, split=", ", fixed=T)) %in% locations_ordered[unique(indexLGD$lgdLoc)]))
      advNeo_multifocal <- as.numeric(grepl(",", advNeo_location, fixed=T))
      if(advNeo_location %in% c("unknown", "colon (NOS)")){
        advNeo_multifocal <- NA
        advNeo_location <- "unknown"
        advNeo_location_same_as_LGD <- NA
      }
    }else{
      advNeo_date_note <- NA
      advNeo_date_source <- NA
      advNeo_date <- "NA"
      advNeo_location <- NA; advNeo_multifocal <- NA
      advNeo_location_same_as_LGD <- NA
    }
    
    # CRC
    if(nrow(crc_pt) != 0){
      crc_date_note <- crc_pt$note
      crc_date_source <- crc_pt$date_source
      crc_date <- crc_pt$first_crc_dx_date
      crc_location <- crc_pt$location
      crc_location_same_as_LGD <- as.numeric(any(unlist(strsplit(crc_pt$location, split=", ", fixed=T)) %in% locations_ordered[unique(indexLGD$lgdLoc)]))
      crc_multifocal <- as.numeric(grepl(",", crc_location, fixed=T))
      if(crc_location %in% c("unknown", "colon (NOS)")){
        crc_multifocal <- NA
        crc_location <- "unknown"
        crc_location_same_as_LGD <- NA
      }
    }else{
      crc_date_source <- NA
      crc_date_note <- NA
      crc_date <- "NA"
      crc_location <- NA; crc_multifocal <- NA
      crc_location_same_as_LGD <- NA
    }
    
    # Get colectomy date
    if(nrow(col_pt) != 0){
      colectomy_date <- col_pt$colectomyDate_llm_cpt
      colectomy_date_source <- col_pt$colectomySource
    }else{
      colectomy_date <- "NA"
      colectomy_date_source <- NA
    }
    
    # Check if patient has PSC ICD code *before or at same time as* index LGD. And after
    if(id %in% psc.df$PatientID){
      if(any(as.Date(psc.df$DxDate[psc.df$PatientID==id]) <= as.Date(uniq_dates[j]), na.rm=T)){
        psc_at_index <- 1
        psc_after_index <- NA
      } else {
        psc_at_index <- 0

        if(any(as.Date(psc.df$DxDate[psc.df$PatientID==id]) <= suppressWarnings(min(as.Date(c(colectomy_date, advNeo_date), format = "%Y-%m-%d"), na.rm=T)), na.rm=T)){
          psc_after_index <- 1
        } else {
          psc_after_index <- 0
        }
      }
      
    }else{
      psc_at_index <- 0
      psc_after_index <- 0
    }
    
    # Get colonoscopy dates, split by structured (CPT, path) and unstructured (LLM) sourcing
    structuredData_colonoscopy_dates <- ptColonoscopy$colonoscopyDate[ptColonoscopy$source != "LLMs"]
    colonoscopy_dates <- ptColonoscopy$colonoscopyDate
    
    colectomy_VA_colonoscopy_dates <- collapse_dates(c(structuredData_colonoscopy_dates, 
                                                       as.Date(colectomy_date, format = "%Y-%m-%d")), 
                                                     window_days = 15, 
                                                     keepers = c(as.Date(colectomy_date, format = "%Y-%m-%d"),
                                                                 as.Date(uniq_dates[j], format="%Y-%m-%d")))
    
    # Get presence of metachronous LGD
    metachronous_lgd <- get_metachronous_lgd(future_path, advNeo_date, colectomy_date, indexLGD, pt, ptColonoscopy$completeDataDate)
      
    # Get the number of follow-up colonoscopies
    fu_colonoscopies <- colonoscopy_dates[which(
      colonoscopy_dates <= suppressWarnings(min(as.Date(c(colectomy_date, advNeo_date), format = "%Y-%m-%d") + 30, na.rm=T)) 
      & colonoscopy_dates > (as.Date(uniq_dates[j], format = "%Y-%m-%d") + 15))]
    num_fu_colonoscopies <- length(fu_colonoscopies)
    if(num_fu_colonoscopies==0){
      fu_colonoscopies <- "NA"
    }
    
    # Get the number of VA documented follow-up colonoscopies
    num_VA_fu_colonoscopies <- length(structuredData_colonoscopy_dates[which(
      structuredData_colonoscopy_dates <= suppressWarnings(min(as.Date(c(colectomy_date, advNeo_date), format = "%Y-%m-%d") + 30, na.rm=T)) 
      & structuredData_colonoscopy_dates > (as.Date(uniq_dates[j], format = "%Y-%m-%d") + 15))])
    
	# Get linked colonoscopy report NoteIDs
    linked_NoteIDs <- paste0(unique(unlist(sapply(indexLGD$TIUDocumentSID.linked[!is.na(indexLGD$TIUDocumentSID.linked)], function(x){
      strsplit(x, split = ", ", fixed=T)
    }))), collapse = ", ")
    
	# Were random biopsies taken?
    random_bx_taken <- as.numeric(any(indexLGD$random_biopsies_taken.unlinked=="yes", na.rm=T))
    
	# If advanced neoplasia date unknown, exclude patient
    if(!is.na(advNeo_date_note) & advNeo_date_note == "Needs manual review"){
      exclude.df <- rbind(exclude.df, data.frame("PatientID" = id, 
                                                 "Reason" = "No Adv. Neo. date. Likely Adv. Neo. before index LGD"))
      break
    }
    
    # Targeted completeness of resection
    targetedCompleteness_vec <- targeted_completeness(indexLGD, completenessOfResection)
    if(length(targetedCompleteness_vec) == 0 & any_invisible==0){
      #completenessTargeted <- "Missing (not run)"
      stop("Completeness of resection not run for non-invisible lesion")
    } else {
      completenessTargeted <- tail(targetedCompleteness_ordered[targetedCompleteness_ordered %in%
                                                                  targetedCompleteness_vec], 1)
      if(length(completenessTargeted)==0){
        completenessTargeted <- "Completeness of resection not run but at least one lesion is invisible"
      }
    }
    
    # Handle unknowns/uncertain/insufficient information in targeted completeness of resection
    if(completenessTargeted %in% c("Insufficient information", "Uncertain")){
      if(completenessOriginal %in% c("not stated", "unknown", "piecemeal") & any_invisible==0){
        exclude.df <- rbind(exclude.df, data.frame("PatientID" = id, "Reason" = "Unknown completeness of resection"))
        break
      }else if(any_invisible == 1){
        completenessTargeted <- "Completeness of resection not known but at least one lesion is invisible"
      }else{
        completenessTargeted <- "Defer to original completeness of resection"
      }
    }
    
    include_ptsRaw <- rbind(include_ptsRaw, data.frame("PatientID" = id,
                                                       "PathologyReportID" = paste0(indexLGD$PathologyReportID[1]),
                                                       "TIUDocumentSIDs.linked" = linked_NoteIDs,
                                                       "Colo_NoteIDs_lastFive" = paste0(unique(pastFive$TIUDocumentSID.unlinked), collapse = ", "),
                                                       "Colo_NoteIDs_nowOrPast" = paste0(unique(nowOrPast$TIUDocumentSID.unlinked), collapse = ", "),
                                                       "previous_IND" = previousIND,
                                                       "metachronous_lgd" = metachronous_lgd,
                                                       "indexLGD_date" = as.Date(uniq_dates[j], format="%Y-%m-%d"),
                                                       "multifocal" = multifocal,
                                                       "large" = large,
                                                       "histo_moderate_severe" = histo_infl,
                                                       "endo_moderate_severe" = endo_infl,
                                                       "endo_moderate_severe_past5" = endo_infl_past5,
                                                       "max_endo_now" = max_endo_now,
                                                       "max_endo_past5" = max_endo_past5,
                                                       "max_endo_next_five_excl_now" = max_endo_nextFive,
                                                       "completenessTargeted" = completenessTargeted,
                                                       "incompleteResection" = completenessOriginal,
                                                       "any_invisible" = any_invisible,
                                                       "index_morphology" = index_morphology,
                                                       "specimen_type" = spec_type,
                                                       "IBD_type" = ibd_type,
                                                       "colitis_associated" = colitis_associated,
                                                       "largest_lesion_location" = indexLGD$lgdLoc[which.max(sizes)],
                                                       "all_indexLGD_locations" = paste0(unique(indexLGD$lgdLoc), collapse = ", "),
                                                       "maximum_colitis_extent" = max_extent,
                                                       "number_fu_colonoscopies" = num_fu_colonoscopies,
                                                       "number_VA_fu_colonoscopies" = num_VA_fu_colonoscopies,
                                                       "last_fu_colonoscopy" = max(as.Date(colonoscopy_dates)),
                                                       "last_VA_fu_colonoscopy" = max(as.Date(structuredData_colonoscopy_dates)),
                                                       "last_VA_fu_colo_or_colectomy" = max(as.Date(colectomy_VA_colonoscopy_dates)),
                                                       "first_fu_colonoscopy" = suppressWarnings(min(as.Date(fu_colonoscopies, format="%Y-%m-%d"))),
                                                       "num_previous_colo_withData" = num_previous_colo_withData,
                                                       "random_bx_taken" = random_bx_taken,
                                                       "bowel_prep_quality" = bowel_prep_quality,
                                                       "landmark_reached" = landmark_reached,
                                                       "PSC_at_index" = psc_at_index,
                                                       "PSC_afterIndex_beforeEvent" = psc_after_index,
                                                       "SmokingStatusAtIndex" = smkStatus,
                                                       "AN_CRC_date" = as.Date(advNeo_date, format="%Y-%m-%d"),
                                                       "AN_CRC_date_note" = advNeo_date_note,
                                                       "AN_CRC_date_source" = advNeo_date_source,
                                                       "AN_CRC_location" = advNeo_location,
                                                       "AN_CRC_location_matches_LGD" = advNeo_location_same_as_LGD,
                                                       "AN_CRC_multifocal" = advNeo_multifocal,
                                                       "CRC_date" = as.Date(crc_date, format="%Y-%m-%d"),
                                                       "CRC_date_note" = crc_date_note,
                                                       "CRC_date_source" = crc_date_source,
                                                       "CRC_location" = crc_location,
                                                       "CRC_location_matches_LGD" = crc_location_same_as_LGD,
                                                       "CRC_multifocal" = crc_multifocal,
                                                       "colectomy_date" = as.Date(colectomy_date, format="%Y-%m-%d"),
                                                       "colectomy_date_source" = colectomy_date_source))
    includeFlag <- T
    break # Only include patient's first date of LGD
  }
  if(!includeFlag & !id %in% exclude.df$PatientID){
    stop("Check unknown reason")
  }
}

write.csv(exclude.df, paste0("./data/exclusions_UCCaRE_", Sys.Date(), ".csv"), row.names=F)

# Rules for considering a lesion "incomplete or invisible"
include_ptsRaw$incomplete_or_invisible <- 0
include_ptsRaw$incomplete_or_invisible[which(include_ptsRaw$completenessTargeted %in% c("R1", "R2") |
    (include_ptsRaw$completenessTargeted == "Defer to original completeness of resection" & include_ptsRaw$incompleteResection=="incomplete"))] <- 1
include_ptsRaw$incomplete_or_invisible[which(include_ptsRaw$any_invisible==1)] <- 1

# Add date of death and last note as censors
df <- merge(include_ptsRaw, base, by = "PatientID", all.x=T)

df$YearOfBirth <- as.numeric(format(as.Date(df$DateOfBirth), "%Y"))
df$YearOfIndex <- as.numeric(format(as.Date(df$indexLGD_date), "%Y"))
df$indexDuringBefore2010 <- as.numeric(df$YearOfIndex <= 2010)
df$indexBefore2015 <- as.numeric(df$YearOfIndex < 2015)

# Add IBD duration 
df$ibd_duration_index <- pmax(as.numeric(difftime(df$indexLGD_date, df$IBDDxDateICD, units="days"))/365.25,
                              as.numeric(difftime(df$indexLGD_date, df$llm_ibd_dx_date_approx, units="days"))/365.25, na.rm=T)
table(df$ibd_duration_index > 0)

df$ibd_duration_index[is.na(df$ibd_duration_index)] <- pmax(0, as.numeric(difftime(df$indexLGD_date, df$IBDDxDateICD, units="days"))/365.25)[
  is.na(df$ibd_duration_index)
]
df$ibd_duration_categorical <- "0-10"
df$ibd_duration_categorical[df$ibd_duration_index >= 11] <- "11-20"
df$ibd_duration_categorical[df$ibd_duration_index > 20] <- ">20"

locations_ordered <- c("rectum", "rectosigmoid", "sigmoid", "descending", "splenic flexure",
                       "transverse", "hepatic flexure", "ascending", "cecum", "ileocecal valve")
df$location_categorical <- "distal to or at splenic flexure"
df$location_categorical[df$largest_lesion_location >= 6] <- "proximal to splenic flexure"
df$colitis_extent_categorical <- "left-sided (sigmoid to splenic flexure)"
df$colitis_extent_categorical[df$maximum_colitis_extent >= 6] <- "extensive (proximal to splenic flexure)"
df$colitis_extent_categorical[df$maximum_colitis_extent == 1] <- "proctitis (rectum only)"


# Convert bowel prep quality back to character
df$bowel_prep <- quality_ordered[df$bowel_prep_quality]
df$bowel_prep[is.na(df$bowel_prep)] <- "unknown"
# df$bowel_prep <- factor(df$bowel_prep, levels = c("excellent", "good", "fair", "poor", "inadequate", "unknown"))
df$landmark <- landmarks_ordered[df$landmark_reached]
df$landmark[df$landmark=="cecum"] <- "cecum or ileum"
df$landmark[df$landmark=="rectosigmoid junction"] <- "sigmoid colon"

# Add additional covariates
df$ageAtIndex <- as.numeric(difftime(df$indexLGD_date, df$DateOfBirth, units="days"))/365.25
df$ageCategorical <- "<40"
df$ageCategorical[df$ageAtIndex >=40] <- "40-59"
df$ageCategorical[df$ageAtIndex >= 60] <- "60+"

# Add binary for completeness by itself
df$completeness_binary <- 0
df$completeness_binary[which(df$completenessTargeted %in% c("R1", "R2") |
                               (df$completenessTargeted == "Defer to original completeness of resection" & df$incompleteResection=="incomplete"))] <- 1
df$completeness_binary[df$any_invisible==1 & df$completeness_binary==0] <- NA

# Collapse location and 'multifocal'
df$AN_CRC_location_multifocal <- df$AN_CRC_location
df$AN_CRC_location_multifocal[grepl(",", df$AN_CRC_location_multifocal, fixed=T)] <- "multifocal"
df$CRC_location_multifocal <- df$CRC_location
df$CRC_location_multifocal[grepl(",", df$CRC_location_multifocal, fixed=T)] <- "multifocal"

# Collapse PSC variables
df$PSC_all <- "no PSC ICD code before censor/event"
df$PSC_all[which(df$PSC_at_index==1)] <- "PSC before or at index"
df$PSC_all[which(df$PSC_afterIndex_beforeEvent==1)] <- "PSC after index but before censor/event"
df$PSC_all <- factor(df$PSC_all, levels = c("no PSC ICD code before censor/event",
                                                          "PSC before or at index",
                                                          "PSC after index but before censor/event"))
df$max_endo_next_five_excl_now[grepl("missing",df$max_endo_next_five_excl_now)] <- NA

# Convert smoking to usable categories
df$SmokingStatusAtIndex[df$SmokingStatusAtIndex=="0"] <- "non-smoker"
df$SmokingStatusAtIndex[df$SmokingStatusAtIndex=="1"] <- "former smoker"
df$SmokingStatusAtIndex[df$SmokingStatusAtIndex=="2"] <- "current smoker"
df$SmokingStatusAtIndex <- relevel(factor(df$SmokingStatusAtIndex), ref = "non-smoker")

write.csv(df, paste0("./data/UCCaRE_preSurvival_", Sys.Date(), ".csv"), row.names=F)

# Survival analysis setup
df$eventDate <- pmin(as.Date(df$AN_CRC_date), 
                     as.Date(df$colectomy_date),
                     as.Date(df$DateOfDeath),
                     as.Date(df$lastNoteDate), na.rm=T)

# Determine event
df$time_to_event <- as.numeric(difftime(df$eventDate, df$indexLGD_date, units = "days"))/365.25
df$time_to_event_days <- df$time_to_event*365.25
df$event <- 0
df$event[df$eventDate==as.Date(df$colectomy_date)] <- 2
df$event[df$eventDate==as.Date(df$AN_CRC_date)] <- 1

# Censor colectomy for Kaplan-Meier analysis
df$eventKM <- df$event
df$eventKM[df$eventKM==2] <- 0
df$eventCombined <- as.numeric(df$event >= 1)

# Recreate UC CARE
colsUCCaRE <- c("large", "incomplete_or_invisible", "multifocal", "endo_moderate_severe")

df_UCCaRE <- remove_unknowns_score(df, colsUCCaRE)

# Get event counts
df_UCCaRE$colectomy <- 0
df_UCCaRE$colectomy[df_UCCaRE$event==2] <- 1
df_UCCaRE$AN <- 0
df_UCCaRE$AN[df_UCCaRE$event==1] <- 1
df_UCCaRE$CRC <- 0
df_UCCaRE$CRC[df_UCCaRE$CRC_date==df_UCCaRE$eventDate] <- 1

# GET NP and P follow-up times
df_UCCaRE$follow_up_NP <- NA
df_UCCaRE$follow_up_NP[df_UCCaRE$event!=1] <- df_UCCaRE$time_to_event[df_UCCaRE$event!=1]
df_UCCaRE$follow_up_P <- NA
df_UCCaRE$follow_up_P[df_UCCaRE$event==1] <- df_UCCaRE$time_to_event[df_UCCaRE$event==1]

# Save to CSV
write.csv(df, paste0("./data/UCCaRE_data_", Sys.Date(), ".csv"), row.names=F)
