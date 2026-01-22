library(VINCI)
library(DBI)
library(VennDiagram)

rm(list=ls())

setwd("<PATH>/IBD_dx")
source("./colectomy/process_colectomy_fn.R") # See step 4B

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = '<SERVER>')

# Get all IBD patients (with PatientID)
cpt_colectomy <- DBI::dbGetQuery(conn, "select base.*, cpt.ProcDate
                      from <SCHEMA>.baseTable_with_llms as base
                      left join
                      <SCHEMA>.colectomy_CPT_allPts_2025_01_13 as cpt
                      on cpt.PatientID = base.PatientID;")

# And raw llama 70B output (with lateAddIBD pts)
llamaRaw <- readLines("./colectomy/llamaRaw/output.txt")
gemma3Raw <- readLines("./colectomy/gemma3Raw/output.txt")
phiRaw <- readLines("./colectomy/phiRaw/output.txt")
mistralRaw <- readLines("./colectomy/mistralRaw/output.txt")

llama.df <- process_colectomy(llamaRaw)
gemma3.df <- process_colectomy(gemma3Raw)
phi.df <- process_colectomy(phiRaw)
mistral.df <- process_colectomy(mistralRaw)

# Add model names with A, B, C, D for sorting
phi.df$llm <- "D_phi4-14B"
gemma3.df$llm <- "C_gemma3-27B"
llama.df$llm <- "A_llama3.3-70B"
mistral.df$llm <- "B_Mistral-24B"

# Put colectomy last and then de-duplicate to get more specific procedure names
llama.df <- llama.df[order(llama.df$Procedure, decreasing = T),]
llama.df <- llama.df[order(grepl("unknown", llama.df$Month, ignore.case = T), decreasing = F),]
llama.df <- llama.df[!(duplicated(llama.df$Year) & duplicated(llama.df$PatientID)),]

gemma3.df <- gemma3.df[order(gemma3.df$Procedure, decreasing = T),]
gemma3.df <- gemma3.df[!(duplicated(gemma3.df$Year) & duplicated(gemma3.df$PatientID)),]

phi.df <- phi.df[order(phi.df$Procedure, decreasing = T),]
phi.df <- phi.df[!(duplicated(phi.df$Year) & duplicated(phi.df$PatientID)),]

mistral.df <- mistral.df[order(mistral.df$Procedure, decreasing = T),]
mistral.df <- mistral.df[!(duplicated(mistral.df$Year) & duplicated(mistral.df$PatientID)),]

# rbind
all_llms <- do.call(rbind, list(phi.df, gemma3.df, llama.df, mistral.df))

# Determine which patients have a "yes" from all four models
colectomy_pts_llms <- Reduce(intersect, list(phi.df$PatientID[grepl("Yes", phi.df$ColectomyYN)],
                               gemma3.df$PatientID[grepl("Yes", gemma3.df$ColectomyYN)],
                               mistral.df$PatientID[grepl("Yes", mistral.df$ColectomyYN)],
                               llama.df$PatientID[grepl("Yes", llama.df$ColectomyYN)]))

# Venn diagram of colectomy at patient level
patient_list <- list(llm=colectomy_pts_llms, cpt=unique(cpt_colectomy$PatientID[!is.na(cpt_colectomy$ProcDate)]))

venn.plot <- draw.pairwise.venn(
  area1=length(patient_list$llm), area2=length(patient_list$cpt),
  cross.area = length(intersect(patient_list$llm, patient_list$cpt)),
  category = c("LLMs", "CPT"),
  fill = c("blue", "red"), alpha=0.5, cat.cex=1.2, cex=1.5, scaled=T
)

# If llama and both other models agree on colectomy year, use that (Certain conf)
# If llama and one other model agree on colectomy year, use that (high conf)
# If llama and one other model are 1-2 years apart, use llama year (med conf)
# If llama and both other models agree on colectomy but not year, mark year as unknown
unique_pts <- unique(colectomy_pts_llms)
out.df <- all_llms[NULL,]
out.df$Supporting_llm <- NULL
out.df$ConfidenceYear <- NULL
add.df <- NULL
for(i in 1:length(unique_pts)){
  
  pt <- all_llms[all_llms$PatientID == unique_pts[i],]
  
  llamaYears <- as.numeric(pt$Year[pt$llm == "A_llama3.3-70B"])
  mistralYears <- as.numeric(pt$Year[pt$llm == "B_Mistral-24B"])
  phiYears <- as.numeric(pt$Year[pt$llm == "D_phi4-14B"])
  gemma3Years <- as.numeric(pt$Year[pt$llm == "C_gemma3-27B"])
  
  phi_matches <- llamaYears[llamaYears %in% phiYears]
  gemma3_matches <- llamaYears[llamaYears %in% gemma3Years]
  mistral_matches <- llamaYears[llamaYears %in% mistralYears]
  
  # Get those that match all
  all_match <- Reduce(intersect, list(llamaYears, gemma3Years, phiYears, mistralYears))
  
  # Get those that match three of four model years
  llama_phi_mistral <- setdiff(Reduce(intersect, list(llamaYears, phiYears, mistralYears)), all_match)
  llama_phi_gemma3 <- setdiff(Reduce(intersect, list(llamaYears, phiYears, gemma3Years)), all_match)
  llama_gemma3_mistral <- setdiff(Reduce(intersect, list(llamaYears, gemma3Years, mistralYears)), all_match)
  three_of_four <- unique(c(llama_phi_gemma3, llama_phi_mistral, llama_gemma3_mistral))
  
  # Get the two of four matches (llama being one)
  llama_phi <- setdiff(Reduce(intersect, list(llamaYears, phiYears)), c(all_match, three_of_four))
  llama_gemma3 <- setdiff(Reduce(intersect, list(llamaYears, gemma3Years)), c(all_match, three_of_four))
  llama_mistral <- setdiff(Reduce(intersect, list(llamaYears, mistralYears)), c(all_match, three_of_four))
  two_of_four <- unique(c(llama_phi, llama_mistral, llama_gemma3))
  
  if(length(all_match) > 0){
    add.df <- pt[pt$Year %in% all_match & pt$llm == "A_llama3.3-70B",]
    add.df$Supporting_llm <- "all 4 have same year"
    add.df$ConfidenceYear <- "Certain"
    out.df <- rbind(out.df, add.df)
  }
  if(length(three_of_four) > 0){
    add.df <- pt[pt$Year %in% three_of_four & pt$llm == "A_llama3.3-70B",]
    add.df$Supporting_llm <- "3 of 4 LLMs have same year"
    add.df$ConfidenceYear <- "High"
    out.df <- rbind(out.df, add.df)
  }
  if(length(llama_mistral) > 0){
    add.df <- pt[pt$Year %in% llama_mistral & pt$llm == "A_llama3.3-70B",]
    add.df$Supporting_llm <- "Mistral-24B only has same year"
    add.df$ConfidenceYear <- "Medium"
    out.df <- rbind(out.df, add.df)
  }
  if(length(llama_phi) > 0){
    add.df <- pt[pt$Year %in% llama_phi & pt$llm == "A_llama3.3-70B",]
    add.df$Supporting_llm <- "Phi-14B only has same year"
    add.df$ConfidenceYear <- "Medium"
    out.df <- rbind(out.df, add.df)
  }
  if(length(llama_gemma3) > 0){
    add.df <- pt[pt$Year %in% llama_gemma3 & pt$llm == "A_llama3.3-70B",]
    add.df$Supporting_llm <- "gemma3-27B only has same year"
    add.df$ConfidenceYear <- "Medium"
    out.df <- rbind(out.df, add.df)
  }
  
  # If no exact matches, look for approximate matches
  if(length(c(gemma3_matches, phi_matches, mistral_matches, all_match))==0){
    for(yr in llamaYears){
      if(suppressWarnings(min(abs(outer(yr, c(phiYears, gemma3Years, mistralYears), "-")), na.rm=T)) <= 2){
        add.df <- pt[pt$Year %in% yr & pt$llm == "A_llama3.3-70B",]
        add.df$Supporting_llm <- "1-2 years from either mistral, gemma3 or phi"
        add.df$ConfidenceYear <- "Low-Medium"
        out.df <- rbind(out.df, add.df)
      }
    }
  }
  
  # If nothing else, confirm colectomy yes
  if(is.null(add.df)){
    add.df <- pt[pt$llm == "A_llama3.3-70B",]
    # Use Llama year, unless its out of range, then use Mistral
    if(!(all(add.df$Year < 2026) & all(add.df$Year > 1900))){
      add.df <- pt[pt$llm == "B_Mistral-24B",]
    }
    add.df$Supporting_llm <- "All models yes to colectomy. No consensus year"
    add.df$ConfidenceYear <- "Low"
    out.df <- rbind(out.df, add.df)
  }
  add.df <- NULL
}

min(out.df$Year, na.rm=T) # 1933
max(out.df$Year, na.rm=T) # 2025
write.csv(out.df, "./colectomy/results/aggregated_colectomy_results_fourModels_2025_04_01.csv", row.names=F)
out.df <- read.csv("./colectomy/results/aggregated_colectomy_results_fourModels_2025_04_01.csv")

combined <- merge(out.df, cpt_colectomy, by = "PatientID", all=T)
combined$ProcDate <- as.Date(combined$ProcDate)

# Keep LLM without confident dates...for now
cpt_or_llm <- combined[!is.na(combined$ProcDate) | grepl("Yes", combined$ColectomyYN),]

# If month is given from LLM, use middle of month, else, use July 1
cpt_or_llm$llm_date <- as.Date(NA)
for(i in 1:nrow(cpt_or_llm)){
  if(!is.na(cpt_or_llm$Year[i]) & cpt_or_llm$Month[i] == "unknown"){
    cpt_or_llm$llm_date[i] <- as.Date(paste0(cpt_or_llm$Year[i], "-07-01"))
  }else if(!is.na(cpt_or_llm$Year[i]) & cpt_or_llm$Month[i] != "unknown"){
    monthNumber <- match(tolower(cpt_or_llm$Month[i]), tolower(month.name))
    if(monthNumber < 10){
      cpt_or_llm$llm_date[i] <- as.Date(paste0(cpt_or_llm$Year[i], "-0", monthNumber, "-15"))
    }else{
      cpt_or_llm$llm_date[i] <- as.Date(paste0(cpt_or_llm$Year[i], "-", monthNumber, "-15"))
    }
  }
}

# Take CPT date unless:
# 1. CPT date is missing
# 2. llm year is two years before CPT year AND has 'Certain' or 'High' confidence
cpt_or_llm$colectomyDate_llm_cpt <- cpt_or_llm$ProcDate
cpt_or_llm$colectomySource <- "CPT"

# Use LLM when CPT is missing
cpt_or_llm$colectomyDate_llm_cpt[is.na(cpt_or_llm$ProcDate)] <- 
  cpt_or_llm$llm_date[is.na(cpt_or_llm$ProcDate)]
cpt_or_llm$colectomySource[is.na(cpt_or_llm$ProcDate)] <- "LLMs"

# Define when to use LLM instead of CPT (both not missing)
index_use_llm <- as.numeric(format(cpt_or_llm$ProcDate, "%Y")) - cpt_or_llm$Year > 2 &
  !is.na(cpt_or_llm$llm_date) & !is.na(cpt_or_llm$ProcDate) &
  cpt_or_llm$ConfidenceYear %in% c("Certain", "High")

# Replace CPT date with LLM date
cpt_or_llm$colectomyDate_llm_cpt[index_use_llm] <- cpt_or_llm$llm_date[index_use_llm]
cpt_or_llm$colectomySource[index_use_llm] <- "LLMs"

# Save
write.csv(cpt_or_llm, "./colectomy/results/colectomy_llms_and_CPT_withDuplicates_2025_04_01.csv", row.names=F)

# Get first CPT colectomy by sorting ProcDate and deleting duplicate llm-ICN combos
cpt_or_llm <- cpt_or_llm[order(cpt_or_llm$ProcDate),]
dedup_cpt <- cpt_or_llm[!duplicated(paste0(cpt_or_llm$PatientID, cpt_or_llm$Year)),]

# De-duplicate llm_cpt colectomy to get first overall
dedup_cpt <- dedup_cpt[order(dedup_cpt$colectomyDate_llm_cpt),]
dup_cpt <- dedup_cpt[dedup_cpt$PatientID %in% dedup_cpt$PatientID[duplicated(dedup_cpt$PatientID)],]
dedup <- dedup_cpt[!duplicated(dedup_cpt$PatientID),]

dedup$llm_Year <- dedup$Year
dedup$llm_Month <- dedup$Month
dedup$cpt_date <- dedup$ProcDate
dedup$segments_removed_llm <- dedup$Segments
dedup$confidence_llm_year <- dedup$ConfidenceYear
dedup_lessCols <- dedup[,c("PatientID", "colectomyDate_llm_cpt", 
                           "colectomySource", "llm_Year", "llm_Month",
                           "cpt_date", "segments_removed_llm", "confidence_llm_year")]


write.csv(dedup_lessCols, "./colectomy/results/firstColectomy_llms_and_CPT_2025_04_01.csv", row.names=F)
dedup_lessCols <- read.csv("./colectomy/results/firstColectomy_llms_and_CPT_2025_04_01.csv")
dbWriteTable(conn, "ibd_colectomy_results_2025_04_23", dedup_lessCols)
 
