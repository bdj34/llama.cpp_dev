# Aggregate CRC diagnoses pulled from free text from Llama 70B and Mistral 24B
# AND include rerun with different excerpts (more context) for either Pos Pts
library(stringr)
library(VINCI)
library(DBI)

rm(list=ls())

setwd("<PATH>")

# Standard db setup
projectName <- '<DATABASE>'
conn <- VINCI_DB(projectName, server = '<SERVER>')

base <-  DBI::dbGetQuery(conn, paste0('select PatientID, DateOfBirth 
                                      from <SCHEMA>.baseTable_with_llms'))

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
    tmp <- unlist(strsplit(inside, split=".", fixed=T))[1]
    if(is.na(tmp)){
      return("Unknown")
    }else{
      return(tmp)
    }
  })
  yearRange <- str_extract_all(llamaYear, "\\d+")
  yearMin <- suppressWarnings(sapply(yearRange, function(x){min(as.numeric(unlist(x)))}))
  yearMin[yearMin > 2025] <- NA
  yearMax <- suppressWarnings(sapply(yearRange, function(x){max(as.numeric(unlist(x)))}))
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

# Get results from first run
firstRun <- read.csv("./free_text_crc/aggregated_output_all_llama70_mistral24_2025_02_20.csv")

# Get the 'either pos' set
eitherPos_run1 <- firstRun[firstRun$mistral_crc_YN | firstRun$llama_crc_YN,]
eitherPos_run1$mistral_month[is.na(eitherPos_run1$mistral_month)] <- "Unknown"
eitherPos_run1$llama_month[is.na(eitherPos_run1$llama_month)] <- "Unknown"

# Mistral re-run
mistralRaw_v2 <- readLines("./free_text_crc/rerun/mistralRaw/output_<DATE_TIME>.txt")
mistral_v2.df <- process_free_text_crc(mistralRaw_v2, "mistral_rerun_")

# Llama re-run
llamaRaw_v2 <-  readLines("./free_text_crc/rerun/llamaRaw/output_<DATE_TIME>.txt")
llama_v2.df <- process_free_text_crc(llamaRaw_v2, "llama_rerun_")

# Gemma3 (re-run only)
gemma3Raw <- readLines("./free_text_crc/rerun/gemma3Raw/output_<DATE_TIME>.txt"))
gemma3.df <- process_free_text_crc(gemma3Raw, "gemma3_rerun_")

# Merge all together
combined_tmp <- merge(mistral_v2.df, llama_v2.df, by = "PatientID")
combined_v2 <- merge(combined_tmp, gemma3.df, by = "PatientID")
all <- merge(combined_v2, eitherPos_run1, by = "PatientID")

# Get all the data in one place and save as csv
all_includeNegativesFromFirstRun <- merge(combined_v2, firstRun, by = "PatientID", all.y=T)
#write.csv(all_includeNegativesFromFirstRun, "./free_text_crc/results/all_outputs_first_and_second_run_2025_04_21.csv", row.names=F)

# Require 4 of 5 to count as a yes.
all$count_crc_pos_outOf5 <- rowSums(all[,c("mistral_crc_YN", "llama_crc_YN", "llama_rerun_crc_YN", 
                                           "mistral_rerun_crc_YN", "gemma3_rerun_crc_YN")])
pos <- all[all$count_crc_pos_outOf5 >= 4,]
pos <- merge(pos, base, by = "PatientID")
pos$YearOfBirth <- format(as.Date(pos$DateOfBirth), "%Y")

# Set rules for getting CRC year
pos$consensus_year <- "No consensus"
pos$consensus_month <- "No consensus"
pos$consensus_confidence_llm_crc_year <- "None"

# Get consensus function (input = 2 vectors and one numeric YOB)
get_consensus_year <- function(min_x, max_x, yob){
  
  umax <- unique(max_x); umin <- unique(min_x)
  
  # Exit early if all NA (unknown)
  if(all(is.na(umax))){
    return(c(NA, "Low"))
  }
  
  # Remove NA
  max_x <- max_x[!is.na(max_x)]
  min_x <- min_x[!is.na(min_x)]
  
  # Get the mode
  mode_max <- umax[which.max(tabulate(match(max_x, umax)))]
  mode_min <- umin[which.max(tabulate(match(min_x, umin)))]
  
  # How many (of 5) is the mode?
  count_max <- sum(max_x==mode_max, na.rm=T)
  count_min <- sum(min_x==mode_min, na.rm=T)
  
  # If the mode is 3+/5, accept that. Give conf score out of 5
  if(count_max %in% c(1, 2)){
    sub_max <- max_x[max_x<(as.numeric(format(Sys.Date(), "%Y"))+1) & max_x>yob]
    #print(sub_max)
    if(length(sub_max)==0){return(c(NA, "Low"))}
    max_year <- round(mean(sub_max))
    spread <- max(sub_max) - min(sub_max)
    if(spread <= 2){
      conf_max <- 2
    }else if (spread <= 5){
      conf_max <- 1
    }else{
      conf_max <- 0
    }
  }else{
    max_year <- mode_max
    conf_max <- count_max
  }
  
  if(count_min %in% c(1, 2)){
    sub_min <- min_x[min_x < (as.numeric(format(Sys.Date(), "%Y"))+1) & min_x > yob]
    #print(sub_min)
    if(length(sub_min)==0){return(c(NA, "Low"))}
    min_year <- round(mean(sub_min))
    spread <- max(sub_min) - min(sub_min)
    if(spread <= 2){
      conf_min <- 2
    }else if (spread <= 5){
      conf_min <- 1
    }else{
      conf_min <- 0
    }
  }else{
    min_year <- mode_min
    conf_min <- count_min
  }
  
  return(c(round(mean(c(min_year, max_year))), conf_max + conf_min))
}


# Ignore models, just get min and max years and feed to function
for(i in 1:nrow(pos)){
  min_years <- as.numeric(pos[i,colnames(pos)[grepl("min_year", colnames(pos), fixed=T)]])
  max_years <- as.numeric(pos[i,colnames(pos)[grepl("max_year", colnames(pos), fixed=T)]])
  out <- get_consensus_year(min_years, max_years, pos$YearOfBirth[i])
  pos$consensus_year[i] <- out[1]
  pos$confidence[i] <- out[2]
}

# Get confidence based on numeric score
pos$consensus_confidence_llm_crc_year <- "Low"
pos$consensus_confidence_llm_crc_year[pos$confidence>=4] <- "Medium"
pos$consensus_confidence_llm_crc_year[pos$confidence>=6] <- "High"
pos$consensus_confidence_llm_crc_year[pos$confidence>=8] <- "Certain"
pos$consensus_confidence_llm_crc_year[is.na(pos$consensus_year)] <- "Low"

# Month (by descending model trustworthiness only): Llama rerun, llama, gemma3 rerun, mistral rerun, mistral
pos$consensus_month <- pos$llama_rerun_month
pos$consensus_month[which(pos$llama_rerun_month == "Unknown")] <- 
  pos$llama_month[which(pos$llama_rerun_month == "Unknown")]
pos$consensus_month[which(pos$consensus_month == "Unknown")] <- 
  pos$gemma3_rerun_month[which(pos$consensus_month == "Unknown")]
pos$consensus_month[which(pos$consensus_month == "Unknown")] <- 
  pos$mistral_rerun_month[which(pos$consensus_month == "Unknown")]
pos$consensus_month[which(pos$consensus_month == "Unknown")] <- 
  pos$mistral_month[which(pos$consensus_month == "Unknown")]

# Make date
# If month is given from LLM, use middle of month, else, use July 1
pos$consensus_year_numeric <- pos$consensus_year
pos$free_text_crc_llm_date <- as.Date(NA)
for(i in 1:nrow(pos)){
  if(!is.na(pos$consensus_year_numeric[i]) & pos$consensus_month[i] == "Unknown"){
    pos$free_text_crc_llm_date[i] <- as.Date(paste0(pos$consensus_year_numeric[i], "-07-01"))
  }else if(!is.na(pos$consensus_year_numeric[i]) & pos$consensus_month[i] != "Unknown"){
    monthNumber <- match(tolower(pos$consensus_month[i]), tolower(month.name))
    if(monthNumber < 10){
      pos$free_text_crc_llm_date[i] <- as.Date(paste0(pos$consensus_year_numeric[i], "-0", monthNumber, "-15"))
    }else{
      pos$free_text_crc_llm_date[i] <- as.Date(paste0(pos$consensus_year_numeric[i], "-", monthNumber, "-15"))
    }
  }
}

# Still some without dates
write.csv(pos, "./free_text_crc/results/positiveOutput_allCols_4of5_postRerun_llama70_mistral24_gemma3_27B_2025_04_21.csv", row.names=F)
colsKeep <- c("PatientID", "free_text_crc_llm_date", "count_crc_pos_outOf5",
              colnames(pos)[grepl("consensus", colnames(pos))])
write.csv(pos[,colsKeep], "./free_text_crc/results/positiveOutput_consensusCols_4of5_postRerun_llama70_mistral24_gemma3_27B_2025_04_21.csv", row.names=F)
check <- pos[,colsKeep]

# Save as SQL table
dbWriteTable(conn, "free_text_crc_ibd_2025_04_23", check)
