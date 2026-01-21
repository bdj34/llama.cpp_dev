# Aggregate ibdYear and decide which patients to feed to llama

rm(list=ls())

setwd("<PATH>")

gemmaRaw <- readLines("./ibdYearAll/gemmaRaw/output_2025-01-27_18-34-42.txt")
phiRaw <- readLines("./ibdYearAll/phiRaw/output_2025-01-27_18-33-31.txt")

# Get years, IDs, Confidence for Phi
phiYear <- sapply(phiRaw, function(x){
  unlist(strsplit(
    unlist(strsplit(x, split = "\\nOriginal diagnosis year: ", fixed=T))[2], 
    split = ". Confidence", fixed = T))[1]
})
phiID <- sapply(phiRaw, function(x){
  unlist(strsplit(x, split = "\t", fixed=T))[2]
})
phiConf <- gsub(".", "", sapply(phiRaw, function(x){
  unlist(strsplit(
    unlist(strsplit(
      unlist(strsplit(x, split = "\\n", fixed=T))[3], 
      split = ". Confidence: ", fixed = T))[2],
    split = "\t", fixed = T))[1]
}), fixed = T)
names(phiID) <- NULL; names(phiYear) <- NULL
names(phiConf) <- NULL

phi.df <- data.frame("PatientICN" = phiID, 
                     "Year" = phiYear,
                     "Confidence" = phiConf)

# Get years, IDs, Confidence, for Gemma
gemmaYear <- sapply(gemmaRaw, function(x){
  unlist(strsplit(
    unlist(strsplit(x, split = "\\nOriginal diagnosis year: ", fixed=T))[2], 
    split = ". Confidence", fixed = T))[1]
})
gemmaID <- sapply(gemmaRaw, function(x){
  unlist(strsplit(x, split = "\t", fixed=T))[2]
})
gemmaConf <- gsub(".", "", sapply(gemmaRaw, function(x){
  unlist(strsplit(
    unlist(strsplit(
      unlist(strsplit(x, split = "\\n", fixed=T))[3], 
      split = ". Confidence: ", fixed = T))[2],
    split = "\t", fixed = T))[1]
}), fixed = T)
names(gemmaID) <- NULL; names(gemmaYear) <- NULL
names(gemmaConf) <- NULL

gemma.df <- data.frame("PatientICN" = gemmaID, 
                     "Year" = gemmaYear,
                     "Confidence" = gemmaConf)

llm.df <- merge(gemma.df, phi.df, by = "PatientICN", suffixes = c("_gemma", "_phi"))

write.csv(llm.df, "./ibdYearAll/output_gemma_phi_2025_01_29.csv", row.names=F)

disagree <- llm.df[llm.df$Year_gemma != llm.df$Year_phi,]
llamaPtIDs <- unique(disagree$PatientICN)

# Read in original txt files for LLM processing and subset to only those with the llamaPtIDs
input <- readLines("./ibdYearAll/original_input/input.txt")
ptIDs <- readLines("./ibdYearAll/original_input/ptIDs.txt")

disputed_input <- input[ptIDs %in% llamaPtIDs]
disputed_ptIDs <- ptIDs[ptIDs %in% llamaPtIDs]

writeLines(disputed_input, "./ibdYearAll/disputed_input_for_llama70/disputed_input.txt")
writeLines(disputed_ptIDs, "./ibdYearAll/disputed_input_for_llama70/disputed_ptIDs.txt")


