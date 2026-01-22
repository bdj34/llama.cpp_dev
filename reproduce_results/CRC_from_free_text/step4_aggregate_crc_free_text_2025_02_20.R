# Aggregate CRC diagnoses pulled from free text from Llama 70B and Mistral 24B
library(stringr)

rm(list=ls())

setwd("<PATH>")

process_free_text_crc <- function(rawOut, prefix = ""){
  llamaYN <- grepl("Yes", rawOut)
  llamaID <- sapply(rawOut, function(x){unlist(strsplit(x, split="\t", fixed = T))[2]})
  llamaConf <- sapply(rawOut, function(x){
    inside <- unlist(strsplit(x, split="Confidence: ", fixed = T))[2]
    unlist(strsplit(inside, split=".", fixed=T))[1]
  })
  llamaYear <- sapply(rawOut, function(x){
    inside <- unlist(strsplit(x, split="\\nDiagnosis year: ", fixed = T))[2]
    unlist(strsplit(inside, split=".", fixed=T))[1]
  })
  llamaMonth <- sapply(rawOut, function(x){
    inside <- unlist(strsplit(x, split="Diagnosis month: ", fixed = T))[2]
    unlist(strsplit(inside, split=".", fixed=T))[1]
  })
  yearRange <- str_extract_all(llamaYear, "\\d+")
  yearMin <- sapply(yearRange, function(x){min(as.numeric(unlist(x)))})
  yearMin[yearMin > 2025] <- NA
  yearMax <- sapply(yearRange, function(x){max(as.numeric(unlist(x)))})
  yearMax[yearMax < 1930] <- NA
  llamaYear[is.na(yearMax) | is.na(yearMin)] <- "Unknown"
  out.df <- data.frame("PatientID" = llamaID,
                       "yn" = llamaYN,
                       "conf" = llamaConf,
                       "yr" = llamaYear,
                       "mo" = llamaMonth, 
                       "min" = yearMin,
                       "max" = yearMax)
  colnames(out.df) <- c("PatientID", paste0(prefix, c("crc_YN", "confidence", 
                                                       "year", "month", 
                                                       "min_year", "max_year")))
  return(out.df)
}

llamaRaw <- readLines("./free_text_crc/llamaRaw/output_<DATE_TIME>.txt")
mistralRaw <- readLines("./free_text_crc/mistralRaw/output_<DATE_TIME>.txt")

mistral.df <- process_free_text_crc(mistralRaw, "mistral_")
llama.df <- process_free_text_crc(llamaRaw, "llama_")

combined.df <- merge(mistral.df, llama.df, by = "PatientID")
write.csv(combined.df, "./free_text_crc/aggregated_output_all_llama70_mistral24_2025_02_20.csv", row.names=F)

eitherPos <- combined.df[combined.df$mistral_crc_YN | combined.df$llama_crc_YN,]
writeLines(eitherPos$PatientID, "./free_text_crc/eitherPos_PatientIDs.txt", useBytes=T)

