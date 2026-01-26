# Bar charts showing predicted and actual risk across groups
library(survival)
library(ggplot2)
library(patchwork)
library(gridExtra)
library(MASS)
library(dplyr)
library(tidyr)
library(ggpattern)
library(ggbreak)

rm(list=ls())
options(warn=1)
source("<PATH>/webtool_validation/fns/UCCARE_fns.R")
source("<PATH>/webtool_validation/fns/calculate_survival_predictions_and_CI.R")

################# SET OPTIONS ##################################################
group_by = "number" # Choose: number (0-4) or binary (0000, 0001, 0010, etc.)
timePlot <- 1
################# END SET OPTIONS ##############################################

# Calculate survival predictions
predict.df <- get_survival_predictions(times)

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

# Reference Kaplan Meier fit
ref_KM <- survfit(Surv(time_to_event, eventKM) ~ 1, data=data)

# Stratified KM fit within each group
data$n_risk_factors <- rowSums(data[,colsUCCaRE])
data$binary_risk_group <- paste0(data$large, data$incomplete_or_invisible, data$multifocal, data$endo_moderate_severe)

# Specify if we want to group by risk factors or groups
if(group_by == "binary"){
  data$group <- data$binary_risk_group
  predict.df$group <- predict.df$group
} else if(group_by == "number"){
  data$group <- data$n_risk_factors
  predict.df$group <- predict.df$n_risk_factors
}else {stop("Set group_by variable to match either 'binary' or 'number'")}

# Group predictions (by # of risk factors (0-4) or binary risk groups (16))
grouped_predictions <- predict.df %>% 
  dplyr::group_by(group, time) %>%
  summarize(AN_risk = 1-mean(S_mean),
            AN_risk_ub = 1-mean(S_lo),
            AN_risk_lb = 1-mean(S_hi), .groups = 'drop')
grouped_predictions$method <- "UC-CaRE prediction"

survFit_byGroup <- survfit(Surv(time_to_event, eventKM) ~ group, data=data)
survFit_summary <- summary(survFit_byGroup, times=times)
KM_results <- data.frame("time" = survFit_summary$time,
                         "AN_risk" = 1-survFit_summary$surv,
                         "AN_risk_lb" = 1 - survFit_summary$upper,
                         "AN_risk_ub" = 1 - survFit_summary$lower,
                         "group" = stringr::str_extract(as.character(survFit_summary$strata), "\\d+"),
                         "method" = "Kaplan-meier")

# Cumulative incidence with competing risks (fine+gray)
cumincfit <- tidycmprsk::cuminc(Surv(time_to_event, factor(event)) ~ group,
                                data=data)
CR_resultsRaw <- tidycmprsk::tidy(cumincfit, times=times)
CR_results1 <- CR_resultsRaw[CR_resultsRaw$outcome=="1",]
CR_results <- data.frame("time" = CR_results1$time,
                         "AN_risk" = CR_results1$estimate,
                         "AN_risk_lb" = CR_results1$conf.low,
                         "AN_risk_ub" = CR_results1$conf.high,
                         "group" = stringr::str_extract(as.character(CR_results1$strata), "\\d+"),
                         "method" = "Competing risks")

grouped_results <- dplyr::bind_rows(grouped_predictions, KM_results, CR_results)

grouped_results$method <- factor(grouped_results$method, levels = c("UC-CaRE prediction", 
                                                                    "Kaplan-meier", 
                                                                    "Competing risks"))
																	
grouped_results <- grouped_results %>%
  dplyr::mutate(
    n_risk_factors = sapply(strsplit(gsub("\\D", "", group), ""), function(d){
      return(sum(as.numeric(d)))
    }
    ))

# Re-order levels of "group" var in binary case
grouped_results$group <- factor(grouped_results$group, 
                                levels = unique(grouped_results$group[order(grouped_results$n_risk_factors)]))

scaler <- 0.2
plot_list1 <- list(); plot_list2 <- list()


# Get results and predictions from this timepoint
res <- grouped_results[grouped_results$time==timePlot,]
KM <- res[res$method=="KM",]
KM_noCol <- res[res$method=="KM_noColectomy",]
CR <- res[res$method=="CRR",]
pred <- grouped_predictions[grouped_predictions$time==timePlot,]
ref <- summary(ref_KM, times=timePlot)

if(timePlot < 1){
time_char <- paste0(timePlot*12, " months")
} else if (timePlot==1){
time_char <- paste0(timePlot, " year")
} else{
time_char <- paste0(timePlot, " years")
}

p1 <- ggplot(res, aes(x=group, y=100*AN_risk, fill=factor(n_risk_factors), pattern=method,
					ymin = 100*AN_risk_lb, ymax = 100*AN_risk_ub)) +
labs(fill="# risk factors", color="# risk factors", pattern = "Prediction vs. observation",
	 pattern_fill = "Prediction vs. observation", pattern_color = "Prediction vs. observation")+
geom_col_pattern(position=position_dodge2(preserve="single"), 
				 aes(pattern_color = method, pattern_fill = method),
				 width=0.9, alpha=.3, pattern_angle = 45,
				 pattern_alpha = 0.8,
				 pattern_density = 0.0007,
				 pattern_key_scale_factor=1,
				 pattern_spacing = 0.012) + 
geom_errorbar(aes(color = factor(n_risk_factors)), 
			  linewidth=0.8,
			  position = position_dodge2(preserve="single")) +
scale_pattern_manual(values=c("UC-CaRE prediction" = "none",
							  "Kaplan-meier" = "stripe", 
							  "Competing risks" = "crosshatch", 
							  "Kaplan-meier w/out colectomy pts." = "stripe")) +
scale_pattern_color_manual(values=c("UC-CaRE prediction" = "white",
									"Kaplan-meier" = "white", 
									"Competing risks" = "white", 
									"Kaplan-meier w/out colectomy pts." = "black")) +
scale_pattern_fill_manual(values=c("UC-CaRE prediction" = "white",
								   "Kaplan-meier" = "white", 
								   "Competing risks" = "white", 
								   "Kaplan-meier w/out colectomy pts." = "black")) +
geom_hline(yintercept = 100*(1-ref$surv), linetype=4, linewidth=1, color = "grey") +
guides(pattern = guide_legend(override.aes = list(fill="black", pattern_alpha=1, alpha=1)),
	   fill = guide_legend(override.aes = list(pattern="none"))) +
ggtitle(time_char) +
ylab(paste0("Probability of advanced neoplasia (%)")) +
xlab("Number of risk factors") +
scale_y_break(c(44, 77), ticklabels = c(80)) +
ylim(0, 84) +
theme_bw() + 
theme_large_text() + 
theme(plot.title = element_text(hjust=0.5, face="bold", size = 16),
	  panel.grid.major.x = element_blank(), panel.grid.minor.x = element_blank(),
	  axis.text.x=element_blank(),axis.ticks.x=element_blank(),
	  axis.title.x=element_blank(),
	  legend.title = element_text(size=14, face="bold"),
	  legend.text = element_text(size=12, face="bold"))


pdf(paste0("./plots/predicted_vs_actual_singleTimepoint_", timePlot, "yr_barPlots_groupedBy-", 
           group_by, "_", Sys.Date(), ".pdf"), width=11, height=7.5)
print(p1)
dev.off()


