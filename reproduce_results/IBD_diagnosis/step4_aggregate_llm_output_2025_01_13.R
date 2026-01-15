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
                      join <schema>.baseTable as base
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

llm.df <- merge(gemma.df, phi.df, by = "PatientID", suffixes = c("_gemma", "_phi"))

table(llm.df$Diagnosis_gemma)
# Make column for IN vs. OUT of IBDC cohort
ibdc_vec <- c("Crohn's with confirmed colitis", "Crohn's colitis", 
              "Crohn's with possible colitis",
              "Ulcerative proctitis", "Ulcerative colitis", 
              "IBD colitis", "Undecided between UC and Crohn's", "UC")
llm.df$IBDC_gemma <- FALSE
# Include if certain/high confidence or path confirmed and medium confidence
llm.df$IBDC_gemma[llm.df$Diagnosis_gemma %in% ibdc_vec & 
                    ((llm.df$Confidence_gemma == "Medium" & llm.df$Path_confirmed_gemma) |
                       llm.df$Confidence_gemma %in% c("Certain", "High"))] <- TRUE
llm.df$IBDC_phi <- FALSE
llm.df$IBDC_phi[llm.df$Diagnosis_phi %in% ibdc_vec & 
                    ((llm.df$Confidence_phi == "Medium" & llm.df$Path_confirmed_phi) |
                       llm.df$Confidence_phi %in% c("Certain", "High"))] <- TRUE

#write.csv(llm.df, "./ibdTypeAll/formatted_output_gemma_phi_2025_01_13.csv", row.names=F)

# See how often they agree/disagree
type.df <- as.data.frame(as.matrix(table(llm.df$Diagnosis_gemma, llm.df$Diagnosis_phi)))
colnames(type.df) <- c("gemma2", "phi4", "Frequency")
type.df <- type.df[type.df$Frequency!=0,]


disagree.df <- llm.df[llm.df$IBDC_gemma != llm.df$IBDC_phi,]
disagreeICNs <- unique(disagree.df$PatientID)
writeLines(disagreeICNs, "./ibdTypeAll/disputedICNs_for_llama70B.txt", useBytes=T)



