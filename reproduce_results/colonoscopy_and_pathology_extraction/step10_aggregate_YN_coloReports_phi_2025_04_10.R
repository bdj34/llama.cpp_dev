# Aggregate the yes no

library(VINCI)
library(DBI)

rm(list = ls())

setwd("<PATH>")

# Get output files and read them
outFiles <- list.files(path = "./yesNo/phiRaw/", pattern = "output", full.names = T)
phiRaw <- unlist(sapply(outFiles, function(x){readLines(x)}))
names(phiRaw) <- NULL

# Get Note IDs and response (yes/no)
phi_ids <- sapply(phiRaw, function(x){unlist(strsplit(x, split = "\t"))[2]})
phi_YN <- grepl("Yes", sapply(phiRaw, function(x){unlist(strsplit(x, split = "\t"))[1]}))

# Check that we have all of them
inputTIU <- readLines("./yesNo/input_NoteIDs.txt")
all(inputTIU %in% phi_ids)
all(phi_ids %in% inputTIU)

# Save to csv
phi.df <- data.frame("NoteID" = phi_ids, "coloRep_YN_phi" = phi_YN)
phi.df <- phi.df[!duplicated(phi.df$NoteID),]
write.csv(phi.df, "./yesNo/results/phi_output_YN_2025_04_10.csv", row.names=F)

pos <- phi.df[phi.df$coloRep_YN_phi,]
write.csv(pos, "./yesNo/results/phi_output_YN_positive_2025_04_10.csv", row.names=F)
