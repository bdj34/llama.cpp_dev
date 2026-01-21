# Aggregate ibdYear and decide which patients to feed to llama

rm(list=ls())

library(ggplot2)

setwd("<PATH>")

llamaRaw <- readLines("./ibdYearAll/llamaRaw/output.txt")

# Get years, IDs, Confidence for llama
llamaYear <- sapply(llamaRaw, function(x){
  unlist(strsplit(
    unlist(strsplit(x, split = "\\nOriginal diagnosis year: ", fixed=T))[2], 
    split = ". Confidence", fixed = T))[1]
})
llamaID <- sapply(llamaRaw, function(x){
  unlist(strsplit(x, split = "\t", fixed=T))[2]
})
llamaConf <- gsub(".", "", sapply(llamaRaw, function(x){
  unlist(strsplit(
    unlist(strsplit(
      unlist(strsplit(x, split = "\\n", fixed=T))[3], 
      split = ". Confidence: ", fixed = T))[2],
    split = "\t", fixed = T))[1]
}), fixed = T)
names(llamaID) <- NULL; names(llamaYear) <- NULL
names(llamaConf) <- NULL

llama.df <- data.frame("PatientICN" = llamaID, 
                     "Year_llama" = llamaYear,
                     "Confidence_llama" = llamaConf)


gemma_phi <- read.csv("./ibdYearAll/output_gemma_phi_2025_01_29.csv")

# Remove the added end of token string
llama.df$Confidence_llama <- gsub("<|eot_id|>", "", llama.df$Confidence_llama, fixed=T)
gemma_phi$Confidence_phi <- gsub("<|im_end|>", "", gemma_phi$Confidence_phi, fixed=T)
gemma_phi$Confidence_gemma <- gsub("<end_of_turn>", "", gemma_phi$Confidence_gemma, fixed=T)
llms <- merge(gemma_phi, llama.df, by = "PatientICN", all.x=T)

# Get max year from range or "During or before..."
llms$Year_gemma_max <- sapply(llms$Year_gemma, function(x){
  max(unlist(stringr::str_extract_all(x, "\\d+")))
})
llms$Year_llama_max <- sapply(llms$Year_llama, function(x){
  max(unlist(stringr::str_extract_all(x, "\\d+")))
})
llms$Year_phi_max <- sapply(llms$Year_phi, function(x){
  max(unlist(stringr::str_extract_all(x, "\\d+")))
})

# Get min year
llms$Year_gemma_min <- sapply(llms$Year_gemma, function(x){
  if(grepl("During", x)){
    return(NA)
  }else{
    min(unlist(stringr::str_extract_all(x, "\\d+")))
  }
})
llms$Year_llama_min <- sapply(llms$Year_llama, function(x){
  if(grepl("During", x)){
    return(NA)
  }else{
    min(unlist(stringr::str_extract_all(x, "\\d+")))
  }
})
llms$Year_phi_min <- sapply(llms$Year_phi, function(x){
  if(grepl("During", x)){
    return(NA)
  }else{
    min(unlist(stringr::str_extract_all(x, "\\d+")))
  }
})


# Design rules for what to be considered a solid year of dx
llms$Year_consensus_text <- NA
llms$Confidence_consensus <- NA

# If llama was run (gemma and phi disagreed), use llama 
llms$Year_consensus_text[is.na(llms$Year_consensus_text)] <- llms$Year_llama[is.na(llms$Year_consensus_text)]
llms$Confidence_consensus[is.na(llms$Confidence_consensus)] <- llms$Confidence_llama[is.na(llms$Confidence_consensus)]

# If gemma and phi agree on a year, exact range, unknown, During or before etc. take that answer.
# Take the confidence level of the larger model (phi)
llms$Year_consensus_text[llms$Year_phi == llms$Year_gemma & is.na(llms$Year_consensus_text)] <- 
  llms$Year_phi[llms$Year_phi == llms$Year_gemma & is.na(llms$Year_consensus_text)]
llms$Confidence_consensus[llms$Year_phi == llms$Year_gemma & is.na(llms$Confidence_consensus)] <- 
  llms$Confidence_phi[llms$Year_phi == llms$Year_gemma & is.na(llms$Confidence_consensus)]

# Take mean of range and leave confidence as is
# If "During or before..." make Confidence = Low
llms$Year_consensus_numeric <- NA
for(i in 1:nrow(llms)){
  if(grepl("During", llms$Year_consensus_text[i])){
    llms$Year_consensus_numeric[i] <- as.numeric(stringr::str_extract(llms$Year_consensus_text[i], "\\d+"))
    llms$Confidence_consensus[i] <- "Low"
  }else{
    llms$Year_consensus_numeric[i] <- floor(mean(as.numeric(unlist(stringr::str_extract_all(llms$Year_consensus_text[i], "\\d+")))))
  }
}

write.csv(llms, "./ibdYearAll/results/output_llama_gemma_phi_2025_03_11.csv", row.names=F)

