library(patchwork)  # for side-by-side panels
library(survivalROC)
library(gridExtra)
library(survminer)
library(dplyr)

rm(list=ls())
options(warn=1)
source("<PATH>/webtool_validation/fns/UCCARE_fns_common.R")
source("<PATH>/webtool_validation/fns/calculate_survival_predictions_and_CI.R")

# Read in the data
df <- read.csv("<PATH>/webtool_validation/data/relaxed_UCCaRE_preSurvival_2025-10-01.csv")

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

# Add binary risk group and number of risk factors
data$n_risk_factors <- rowSums(data[,colsUCCaRE])
data$binary_risk_group <- paste0(data$large, data$incomplete_or_invisible, data$multifocal, data$endo_moderate_severe)

################ Show just the low risk group ##################################
times <- seq(0, 10, by = 0.1)

# Ref fit
survFit <- survfit(Surv(time_to_event, eventKM) ~ 1, data=data)
survFit_ref <- summary(survFit, times=times)
KM_ref <- data.frame("time" = survFit_ref$time,
                     "AN_risk" = 1-survFit_ref$surv,
                     "AN_risk_lb" = 1 - survFit_ref$upper,
                     "AN_risk_ub" = 1 - survFit_ref$lower,
                     "group" =  "NA",
                     "method" = "Unstratified KM (reference)")

# Stratified KM fit
survFit_byGroup <- survfit(Surv(time_to_event, eventKM) ~ binary_risk_group, data=data)
survFit_summary <- summary(survFit_byGroup, times=times)
KM_results <- data.frame("time" = survFit_summary$time,
                         "AN_risk" = 1-survFit_summary$surv,
                         "AN_risk_lb" = 1 - survFit_summary$upper,
                         "AN_risk_ub" = 1 - survFit_summary$lower,
                         "group" = stringr::str_extract(as.character(survFit_summary$strata), "\\d+"),
                         "method" = "Kaplan-meier")

# Cumulative incidence with competing risks (fine+gray)
cumincfit <- tidycmprsk::cuminc(Surv(time_to_event, factor(event)) ~ binary_risk_group,
                                data=data)
CR_resultsRaw <- tidycmprsk::tidy(cumincfit, times=times)
CR_results1 <- CR_resultsRaw[CR_resultsRaw$outcome=="1",]
CR_results <- data.frame("time" = CR_results1$time,
                         "AN_risk" = CR_results1$estimate,
                         "AN_risk_lb" = CR_results1$conf.low,
                         "AN_risk_ub" = CR_results1$conf.high,
                         "group" = stringr::str_extract(as.character(CR_results1$strata), "\\d+"),
                         "method" = "Competing risks")

# Calculate survival predictions
predict.df <- get_survival_predictions(times)
# Group predictions (by # of risk factors (0-4) or binary risk groups (16))
grouped_predictions <- predict.df %>% 
  dplyr::group_by(group, time) %>%
  summarize(AN_risk = 1-mean(S_mean),
            AN_risk_ub = 1-mean(S_lo),
            AN_risk_lb = 1-mean(S_hi), .groups = 'drop')
grouped_predictions$method <- "UC-CaRE prediction"

combined <- dplyr::bind_rows(grouped_predictions, KM_results, CR_results, KM_ref)
combined$method <- factor(combined$method, levels = c("UC-CaRE prediction", "Kaplan-meier",
                                                      "Competing risks", "Unstratified KM (reference)"))
loRisk <- combined[combined$group == "0000",]
loRiskRef <- combined[combined$group %in% c("0000", "NA"),]

pLoRef <- ggplot(loRiskRef, aes(x=time, fill=method)) + 
  geom_line(aes(y=100*AN_risk, color = method, linetype=method), linewidth=0.7) +
  geom_ribbon(data=loRiskRef, 
              aes(ymin=100*AN_risk_ub, ymax = 100*AN_risk_lb, alpha=method)) +
  theme_bw() +
  scale_color_manual(values = c("UC-CaRE prediction"="black",
                                "Kaplan-meier" = "#F8766D",
                                "Competing risks" = "#F8766D", 
                                "Unstratified KM (reference)" = "grey"
  )) +
  scale_alpha_manual(values = c("UC-CaRE prediction"=0.1,
                                "Kaplan-meier" = 0.2,
                                "Competing risks" = 0,
                                "Unstratified KM (reference)"=0.1)) +
  scale_fill_manual(values = c("UC-CaRE prediction"="black",
                               "Kaplan-meier" = "#F8766D",
                               "Competing risks" = "#F8766D",
                               "Unstratified KM (reference)"="grey")) +
  scale_linetype_manual(values = c("UC-CaRE prediction"=1,
                                   "Kaplan-meier" = 1,
                                   "Competing risks" = 2,
                                   "Unstratified KM (reference)"=1)) +
  ggtitle("Risk prediction: 0 risk factors (n = 1427)") +
  theme_large_text() + 
  theme(legend.position = "right", legend.key.size = unit(1.5, "lines"),
        plot.title=element_text(hjust=0.5, face="bold", size=14)) +
  xlab("Time (years)") + ylab("Probability of advanced neoplasia (%)")

pdf(paste0("./plots/loRisk_relaxed_prediction_vs_KM-CR-ref_", Sys.Date(), ".pdf"), width=10.5, height=6.5)
pLoRef
dev.off()
