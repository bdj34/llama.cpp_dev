# Plot to 5 years UC-CaRE 
library(patchwork)  # for side-by-side panels
library(survivalROC)
library(gridExtra)
library(survminer)
library(dplyr)
library(survival)

rm(list=ls())
source("<PATH>/webtool_validation/fns/UCCARE_fns.R") # see step 1B

# Read in the data
df <- read.csv("<PATH>/webtool_validation/data/UCCaRE_preSurvival_2025-10-20.csv")

# Survival analysis setup
df$eventDate <- pmin(as.Date(df$AN_CRC_date), 
                     as.Date(df$colectomy_date),
                     as.Date(df$DateOfDeath),
                     as.Date(df$lastNoteDate), na.rm=T)


# Determine event
df$time_to_event <- as.numeric(difftime(df$eventDate, df$indexLGD_date, units = "days"))/365.25
df$time_to_event_days <- df$time_to_event*365.25

df$event <- 0
df$event[df$eventDate==as.Date(df$colectomy_date)] <- 2
df$event[df$eventDate==as.Date(df$AN_CRC_date)] <- 1

# Censor colectomy for KM analysis
df$eventKM <- df$event
df$eventKM[df$eventKM==2] <- 0
df$eventCombined <- as.numeric(df$event >= 1)

# Recreate UC CARE
colsUCCaRE <- c("large", "incomplete_or_invisible", "multifocal", "endo_moderate_severe")

data <- remove_unknowns_score(df, colsUCCaRE)

data$group <- factor(data$score, levels = c("0", "1", "2", "3", "4"))
survFit <- survfit(Surv(time_to_event, eventKM) ~ group, data=data)

pSurv <- ggsurvplot(survFit, data=data, risk.table=T, cumevents=F,
                    break.time.by =1, xlim = c(0,5), ylim=c(0.65, 1),
                    legend.title = "Number of risk factors",
                    legend.labs = c("0", "1", "2", "3", "4"),
                    ylab = "Probability of remaining HGD/CRC free",
                    xlab="Time (yrs)")
pSurv$table <- pSurv$table + ylab("")

pdf(paste0("./plots/KM_colectomyAsCensor_forFig1_UCCaRE_", Sys.Date(), ".pdf"))
pSurv
dev.off()
