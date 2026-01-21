# Get results from the LLMs (Phi-4-14B and Gemma-2-9B-SPPO)
# about IBD status

library(VINCI)
library(DBI)

# Remove vars
rm(list = ls())

setwd("<PATH>")

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = '<SERVER>')

# Get all IBD patients (with PatientSID)
allIBD_pts <- DBI::dbGetQuery(conn, "select PatientSID, base.* from CohortCrosswalk as coh
                      join <SCHEMA>.baseTable as base
                      on coh.PatientID = base.PatientID
                      where base.IBDDxDateICD is not null;")

# Read in raw gemma output
gemmaRaw1 <- readLines("./ibdTypeAll/raw_output/output_2025-01-09_14-46-05.txt")
gemmaRaw2 <- readLines("./ibdTypeAll/raw_output/output_2025-01-10_17-24-23.txt")
gemmaRaw3 <- readLines("./ibdTypeAll/raw_output/output_2025-01-12_03-13-26.txt")
gemmaRaw <- c(gemmaRaw1, gemmaRaw2, gemmaRaw3)

# and raw phi output
phiRaw1 <- readLines("./ibdTypeAll/raw_output/output_2025-01-09_14-48-59.txt")
phiRaw2 <- readLines("./ibdTypeAll/raw_output/output_2025-01-10_15-39-01.txt")
phiRaw3 <- readLines("./ibdTypeAll/raw_output/output_2025-01-12_04-08-47.txt")
phiRaw <- c(phiRaw1, phiRaw2, phiRaw3)

# And raw llama 70B output (where these disagree)
llamaRaw <- readLines("./ibdTypeAll/raw_output/output_2025-01-13_16-00-33.txt")


# Get types, IDs, Confidence, Path confirmed
phiType <- sapply(phiRaw, function(x){
  unlist(strsplit(
    unlist(strsplit(x, split = "\\nDiagnosis: ", fixed=T))[2], 
                  split = ". Confidence", fixed = T))[1]
})
phiID <- sapply(phiRaw, function(x){
    unlist(strsplit(x, split = "\t", fixed=T))[2]
})
phiConf <- sapply(phiRaw, function(x){
  unlist(strsplit(
  unlist(strsplit(
    unlist(strsplit(x, split = "\\nDiagnosis: ", fixed=T))[2], 
    split = ". Confidence: ", fixed = T))[2],
  split = "\\n", fixed = T))[1]
})
phiPath <- sapply(phiRaw, function(x){
  grepl("Yes",
    unlist(strsplit(x, split = "\\nPathology or endoscopy confirmed: ", fixed=T))[2])
})
names(phiID) <- NULL; names(phiType) <- NULL
names(phiConf) <- NULL; names(phiPath) <- NULL

phi.df <- data.frame("PatientID" = phiID, 
                     "Diagnosis" = phiType,
                     "Confidence" = phiConf, 
                     "Path_confirmed" = phiPath)

# Now do the same for gemma
gemmaType <- sapply(gemmaRaw, function(x){
  unlist(strsplit(
    unlist(strsplit(x, split = "\\nDiagnosis: ", fixed=T))[2], 
    split = ". Confidence", fixed = T))[1]
})
gemmaID <- sapply(gemmaRaw, function(x){
  unlist(strsplit(x, split = "\t", fixed=T))[2]
})
gemmaConf <- sapply(gemmaRaw, function(x){
  unlist(strsplit(
    unlist(strsplit(
      unlist(strsplit(x, split = "\\nDiagnosis: ", fixed=T))[2], 
      split = ". Confidence: ", fixed = T))[2],
    split = "\\n", fixed = T))[1]
})
gemmaPath <- sapply(gemmaRaw, function(x){
  grepl("Yes",
        unlist(strsplit(x, split = "\\nPathology or endoscopy confirmed: ", fixed=T))[2])
})
names(gemmaID) <- NULL; names(gemmaType) <- NULL
names(gemmaConf) <- NULL; names(gemmaPath) <- NULL

gemma.df <- data.frame("PatientID" = gemmaID, 
                     "Diagnosis" = gemmaType,
                     "Confidence" = gemmaConf, 
                     "Path_confirmed" = gemmaPath)

# Now do the same for llama
llamaType <- sapply(llamaRaw, function(x){
  unlist(strsplit(
    unlist(strsplit(x, split = "\\nDiagnosis: ", fixed=T))[2], 
    split = ". Confidence", fixed = T))[1]
})
llamaID <- sapply(llamaRaw, function(x){
  unlist(strsplit(x, split = "\t", fixed=T))[2]
})
llamaConf <- sapply(llamaRaw, function(x){
  unlist(strsplit(
    unlist(strsplit(
      unlist(strsplit(x, split = "\\nDiagnosis: ", fixed=T))[2], 
      split = ". Confidence: ", fixed = T))[2],
    split = "\\n", fixed = T))[1]
})
llamaPath <- sapply(llamaRaw, function(x){
  grepl("Yes",
        unlist(strsplit(x, split = "\\nPathology or endoscopy confirmed: ", fixed=T))[2])
})
names(llamaID) <- NULL; names(llamaType) <- NULL
names(llamaConf) <- NULL; names(llamaPath) <- NULL

llama.df <- data.frame("PatientID" = llamaID, 
                       "Diagnosis_llama" = llamaType,
                       "Confidence_llama" = llamaConf, 
                       "Path_confirmed_llama" = llamaPath)

llm.df_tmp <- merge(gemma.df, phi.df, by = "PatientID", suffixes = c("_gemma", "_phi"))
llm.df <- merge(llm.df_tmp, llama.df, by = "PatientID", all.x=T)


# Make column for IN vs. OUT of IBDC cohort
ibdc_vec <- c("Crohn's with confirmed colitis", "Crohn's colitis", 
              "Crohn's with possible colitis",
              "Ulcerative proctitis", "Ulcerative colitis", 
              "IBD colitis", "Undecided between UC and Crohn's", "UC")
llm.df$IBDC <- FALSE

# If llama says yes, it's a yes (only ran llama where gemma and phi disagreed)
llm.df$IBDC[llm.df$Diagnosis_llama %in% ibdc_vec & 
              ((llm.df$Confidence_llama == "Medium" & llm.df$Path_confirmed_llama) |
                 llm.df$Confidence_llama %in% c("Certain", "High"))] <- TRUE

# If gemma and phi models agree with Medium & path or High+, it's a yes
llm.df$IBDC[(llm.df$Diagnosis_gemma %in% ibdc_vec & 
              ((llm.df$Confidence_gemma == "Medium" & llm.df$Path_confirmed_gemma) |
                 llm.df$Confidence_gemma %in% c("Certain", "High"))) &
            (llm.df$Diagnosis_phi %in% ibdc_vec & 
              ((llm.df$Confidence_phi == "Medium" & llm.df$Path_confirmed_phi) |
                 llm.df$Confidence_phi %in% c("Certain", "High")))] <- TRUE

# If both models say "undecided between UC and Crohn's" at Medium+ confidence, it's a yes (even without path confirmed)
undecided <- c("IBD colitis", "Undecided between UC and Crohn's")
llm.df$IBDC[(llm.df$Diagnosis_gemma %in% undecided & llm.df$Confidence_gemma != "Low")  &
              (llm.df$Diagnosis_phi %in% undecided & llm.df$Confidence_phi != "Low") &
              is.na(llm.df$Diagnosis_llama)] <- TRUE

# Similarly, if Llama says Undecided and Medium confidence, it's a yes (even without path confirmed)
llm.df$IBDC[(llm.df$Diagnosis_llama %in% undecided & llm.df$Confidence_llama != "Low")] <- TRUE

table(llm.df$IBDC)

# Get the diagnosis
llm.df$diagnosis <- llm.df$Diagnosis_llama
llm.df$diagnosis[is.na(llm.df$Diagnosis_llama) & 
                   llm.df$Diagnosis_gemma == llm.df$Diagnosis_phi] <- llm.df$Diagnosis_gemma[is.na(llm.df$Diagnosis_llama) & 
                                                                               llm.df$Diagnosis_gemma == llm.df$Diagnosis_phi]
proc_uc <- c("Ulcerative proctitis", "Ulcerative colitis", "UC")
crohns_col <- c("Crohn's with confirmed colitis", "Crohn's colitis", "Crohn's with possible colitis")
llm.df$diagnosis[is.na(llm.df$diagnosis) & llm.df$Diagnosis_gemma %in% proc_uc & llm.df$Diagnosis_phi %in% proc_uc] <- "Ulcerative colitis"
llm.df$diagnosis[is.na(llm.df$diagnosis) & llm.df$Diagnosis_gemma %in% undecided & llm.df$Diagnosis_phi %in% proc_uc] <- "Ulcerative colitis"
llm.df$diagnosis[is.na(llm.df$diagnosis) & llm.df$Diagnosis_gemma %in% proc_uc & llm.df$Diagnosis_phi %in% undecided] <- "Ulcerative colitis"
llm.df$diagnosis[is.na(llm.df$diagnosis) & llm.df$Diagnosis_gemma %in% undecided & llm.df$Diagnosis_phi %in% crohns_col] <- "Crohn's colitis"
llm.df$diagnosis[is.na(llm.df$diagnosis) & llm.df$Diagnosis_gemma %in% crohns_col & llm.df$Diagnosis_phi %in% undecided] <- "Crohn's colitis"
llm.df$diagnosis[is.na(llm.df$diagnosis) & llm.df$Diagnosis_gemma %in% crohns_col & llm.df$Diagnosis_phi %in% crohns_col] <- "Crohn's colitis"
llm.df$diagnosis[is.na(llm.df$diagnosis) & llm.df$Diagnosis_gemma %in% crohns_col & llm.df$Diagnosis_phi %in% proc_uc] <- "IBD-U"
llm.df$diagnosis[is.na(llm.df$diagnosis) & llm.df$Diagnosis_gemma %in% proc_uc & llm.df$Diagnosis_phi %in% crohns_col] <- "IBD-U"
llm.df$diagnosis[is.na(llm.df$diagnosis) & llm.df$Diagnosis_gemma %in% undecided & llm.df$Diagnosis_phi %in% undecided] <- "IBD-U"

# CLean up naming of diagnoses
llm.df$diagnosis[llm.df$diagnosis %in% crohns_col] <- "Crohn's colitis"
llm.df$diagnosis[llm.df$diagnosis %in% undecided] <- "IBD-U"

# See if there's uncertainty in the diagnosis
llm.df$diagnostic_odyssey <- F
llm.df$diagnostic_odyssey[llm.df$Diagnosis_gemma %in% undecided] <- T
llm.df$diagnostic_odyssey[llm.df$Diagnosis_phi %in% undecided] <- T
llm.df$diagnostic_odyssey[llm.df$Diagnosis_llama %in% undecided] <- T
llm.df$diagnostic_odyssey[llm.df$diagnosis == "IBD-U"] <- T

table(is.na(llm.df$diagnosis), as.numeric(llm.df$IBDC))
table(llm.df$diagnostic_odyssey,  as.numeric(llm.df$IBDC))
table(llm.df$diagnosis[llm.df$IBDC])

# Determine if path confirmed
llm.df$path_confirmed <- FALSE
llm.df$path_confirmed[llm.df$Path_confirmed_llama] <- T
llm.df$path_confirmed[llm.df$Path_confirmed_gemma & llm.df$Path_confirmed_phi] <- T
table(llm.df$path_confirmed, as.numeric(llm.df$IBDC))

write.csv(llm.df, "./ibdTypeAll/formatted_output_llama_gemma_phi_2025_01_28.csv", row.names=F)

llm_base <- llm.df[llm.df$IBDC,c("PatientID", "IBDC", "diagnosis", "path_confirmed", "diagnostic_odyssey")]
colnames(llm_base) <- c("PatientID", "IBDC", "diagnosis", "pathConfirmed", "diagnosticOdyssey")

# Make a database table with the positives
DBI::dbWriteTable(conn, "baseTable_with_llms", llm_base)


