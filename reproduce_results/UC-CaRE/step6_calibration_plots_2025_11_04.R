# Calibration plots
library(patchwork)  # for side-by-side panels
library(survminer)
library(dplyr)
library(ggplot2)
library(survival)
library(ggsurvfit)
library(stringr)

rm(list=ls())
options(warn=1)
source("<PATH>/webtool_validation/fns/UCCARE_fns.R")
source("<PATH>/webtool_validation/fns/calculate_survival_predictions_and_CI.R")

tPlot <- 10

# Read in the data
df <- read.csv("<PATH>/webtool_validation/data/UCCaRE_preSurvival_2025-10-20.csv")

# Survival analysis setup
df$eventDate <- pmin(as.Date(df$AN_CRC_date), 
                     as.Date(df$colectomy_date),
                     as.Date(df$DateOfDeath),
                     as.Date(df$lastNoteDate), na.rm=T)

# Separate analysis of censoring at next colonoscopy
df2 <- df
df2$eventDate[which(df2$first_fu_colonoscopy < df2$eventDate & df2$first_fu_colonoscopy > df2$indexLGD_date)] <- 
  df2$first_fu_colonoscopy[which(df2$first_fu_colonoscopy < df2$eventDate & df2$first_fu_colonoscopy > df2$indexLGD_date)]

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

# Determine event
df2$time_to_event <- as.numeric(difftime(df2$eventDate, df2$indexLGD_date, units = "days"))/365.25
df2$time_to_event_days <- df2$time_to_event*365.25
df2$event <- 0
df2$event[df2$eventDate==as.Date(df2$colectomy_date)] <- 2
df2$event[df2$eventDate==as.Date(df2$AN_CRC_date)] <- 1
# Censor colectomy for KM analysis
df2$eventKM <- df2$event
df2$eventKM[df2$eventKM==2] <- 0
df2$eventCombined <- as.numeric(df2$event >= 1) 

# Get risk groups
colsUCCaRE <- c("large", "incomplete_or_invisible", "multifocal", "endo_moderate_severe")
data <- remove_unknowns_score(df, colsUCCaRE)
data$binary_coding <- get_binary_risk_groups(data)
data$binary_coding_numbers <- paste0(data$large, data$incomplete_or_invisible, data$multifocal, data$endo_moderate_severe)
data2 <- remove_unknowns_score(df2, colsUCCaRE)
data2$binary_coding <- get_binary_risk_groups(data2)
data2$binary_coding_numbers <- paste0(data2$large, data2$incomplete_or_invisible, data2$multifocal, data2$endo_moderate_severe)


# Get predictions, including by propagating uncertainty
timesPlot <- seq(0, tPlot, 0.01)
predict.df <- get_survival_predictions(timesPlot)
predict.df_prop <- get_survival_predictions_propagate_uncertainty(timesPlot)

# Get color defaults from: scales::hue_pal()(5)
colorScale <- c("0" = "#F8766D", "1" = "#A3A500", "2" = "#00BF7D", "3" = "#00B0F6", "4" = "#E76BF3")
colorScale_strata <- colorScale
names(colorScale_strata) <- paste0("score=", names(colorScale))

#  Plot for all 16 binary risk groups
plot.list_dub <- list()
groups <- unique(predict.df$group[order(predict.df$n_risk_factors)])
titleSize <- 9
axisSize <- 9
for(group in groups){

  tmp.df <- data[data$binary_coding_numbers==group,]
  n_pts <- nrow(tmp.df)
  pred <- predict.df[predict.df$group == group,]
  pred_prop <- predict.df_prop[predict.df_prop$group == group,]
  n_risk <- tmp.df$score[1]
  
  tmp.df_nC <- data2[data2$binary_coding_number==group,]
  
  survFit_tmp <- summary(survfit(Surv(time_to_event, eventKM) ~ 1, data=tmp.df), times=timesPlot)
  fit.df <- data.frame("time" = survFit_tmp$time,
                       "surv" = survFit_tmp$surv,
                       "lower" = survFit_tmp$lower,
                       "upper" = survFit_tmp$upper)
  
  survFit_tmp_nC <- summary(survfit(Surv(time_to_event, eventKM) ~ 1, data=tmp.df_nC), times=timesPlot)
  fit.df_nC <- data.frame("time" = survFit_tmp_nC$time,
                          "surv" = survFit_tmp_nC$surv,
                          "lower" = survFit_tmp_nC$lower,
                          "upper" = survFit_tmp_nC$upper)
 
  p_surv_dub <- ggplot(fit.df) + 
    geom_line(aes(x=time, y=surv), color = colorScale[n_risk+1]) +
    geom_line(data=fit.df_nC, aes(x=time, y=surv), color = colorScale[n_risk+1], linetype="dashed") +
    geom_ribbon(data=fit.df_nC, aes(x=time, ymin=lower, ymax=upper), fill = colorScale[n_risk+1], alpha=0.2) +
    geom_ribbon(aes(x=time, ymin=lower, ymax=upper), fill = colorScale[n_risk+1], alpha=0.2) +
    geom_line(data=pred, aes(x=time, y=S_mean), 
              color="black") +
    geom_ribbon(data=pred, aes(x=time, ymin=S_lo, ymax=S_hi), 
                fill="black", alpha=0.08) +
    geom_ribbon(data=pred_prop, aes(x=time, ymin=S_lo, ymax=S_hi), 
                fill="black", alpha=0.08) +
    xlab("Time (years)") + ylab("Probability of remaining HGD/CRC free") +
    ylim(0, 1) +
    theme_bw() +
    ggtitle(str_wrap(paste0(tmp.df$binary_coding, " (n=", n_pts, ")"), width=40)) + 
    theme(plot.title=element_text(size=titleSize, hjust=0.5), axis.title=element_blank(),
          axis.text=element_text(size=axisSize))
  
  plot.list_dub <- c(plot.list_dub, list(p_surv_dub))
}

# Double uncertainty
saveRDS(plot.list_dub, paste0("./plots/calibration_plots_byBinaryGrouping_doubleUncertainty_withCensorNextColo_10yr_", Sys.Date(), ".rds"))
pdf(paste0("./plots/calibration_plots_byBinaryGrouping_doubleUncertainty_withCensorNextColo_10yr_", Sys.Date(), ".pdf"), height=12, width=18)
patchwork::wrap_plots(plot.list_dub, guides="collect")
dev.off()

