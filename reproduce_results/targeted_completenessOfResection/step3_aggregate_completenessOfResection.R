# Aggregate additional inputs for completeness of resection for uc-care
# Status: Done. 
# 27B refers to medGemma-27B-Q4KM (text only)

rm(list = ls())

# Get files
files_medGemma_27B <- list.files(path = "<PATH>/completenessOfResection/raw_output/medGemma_27B",
                            pattern="output", full.names=T)

# Read in and process
raw_medGemma_27B <- unlist(lapply(files_medGemma_27B, function(x){readLines(x[1])}))
id_medGemma_27B <- sapply(raw_medGemma_27B, function(x){strsplit(x, split = "\t", fixed=T)[[1]][2]})
PathReportID_medGemma_27B <- sapply(id_medGemma_27B, function(x){strsplit(x, split = "_", fixed = T)[[1]][1]})
ColoReportID_medGemma_27B <- sapply(id_medGemma_27B, function(x){strsplit(x, split = "_", fixed = T)[[1]][3]})
sampleID_medGemma_27B <- sapply(id_medGemma_27B, function(x){strsplit(x, split = "_", fixed = T)[[1]][2]})
answer_medGemma_27B <- sapply(raw_medGemma_27B, function(x){strsplit(
                                        strsplit(x, split = "<", fixed=T)[[1]][1], 
                                                   split = ": ", fixed=T)[[1]][2]})

out_medGemma_27B_withDup <- data.frame("combinedID" = id_medGemma_27B,
                      "PathologyReportID" = PathReportID_medGemma_27B, 
                      "ColonoscopyReportID" = ColoReportID_medGemma_27B,
                      "sampleID" = sampleID_medGemma_27B,
                      "answer_27B" = answer_medGemma_27B)
out_medGemma_27B <- out_medGemma_27B_withDup[!duplicated(out_medGemma_27B_withDup),]

# Write to csv
write.csv(out_medGemma_27B, paste0("<PATH>/completenessOfResection/",
  "results/aggregated_completeness_medGemma_27B_", Sys.Date(), ".csv"), row.names=F)

