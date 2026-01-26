# Make the all-follow-up plot
library(ggplot2)
library(survival)
library(ggsurvfit)
library(survminer)

rm(list=ls())

source("<PATH>/webtool_validation/fns/UCCARE_fns.R")

# Read in the data
df <- read.csv("<PATH>/webtool_validation/data/relaxed_UCCaRE_preSurvival_2025-10-20.csv")

# Survival analysis setup
df$eventDate <- pmin(as.Date(df$AN_CRC_date), 
                     as.Date(df$colectomy_date),
                     as.Date(df$DateOfDeath),
                     as.Date(df$lastNoteDate), na.rm=T)

# Determine event/time to event
df$time_to_event <- as.numeric(difftime(df$eventDate, df$indexLGD_date, units = "days"))/365.25

df$event <- 0
df$event[df$eventDate==as.Date(df$colectomy_date)] <- 2
df$event[df$eventDate==as.Date(df$AN_CRC_date)] <- 1

# Censor colectomy for KM analysis
df$eventKM <- df$event
df$eventKM[df$eventKM==2] <- 0
df$eventCombined <- as.numeric(df$event >= 1)

# Get risk groups
colsUCCaRE <- c("large", "incomplete_or_invisible", "multifocal", "endo_moderate_severe")
data <- remove_unknowns_score(df, colsUCCaRE)

data$group <- factor(data$score, levels = c("0", "1", "2", "3", "4"))
survFit <- survfit(Surv(time_to_event, eventKM) ~ group, data=data)

pSave <- ggsurvplot(survFit, data=data, risk.table=T,
                    break.time.by = 5)+ xlab("Time (years)")
saveRDS(pSave, paste0("./plots/KM_colectomyAsCensor_relaxed_allFollowUp_UCCaRE_", Sys.Date(), ".rds"))

# Plot and save the KM analysis
pdf(paste0("./plots/KM_colectomyAsCensor_relaxed_allFollowUp_UCCaRE_", Sys.Date(), ".pdf"))
pSave
dev.off()

