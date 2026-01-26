# Get the PPV, NPV, sensitivity, specificity etc. of UC-CaRE LLM validations
rm(list=ls())

# PATH: change to your path
setwd("~/VA_IBD/UC-CaRE/review_llm_metrics/for_github/")

# Read in the tables
val <- read.csv("./deID_reviewed_subset_for_github_2026-01-26.csv")
prevRaw <- read.csv("./deID_prevalence_for_github_2026-01-26.csv")

prevRaw$score <- rowSums(prevRaw[,c("multifocal", "large", "endo_moderate_severe",
                                    "incomplete_or_invisible")])
prev_score <- as.data.frame(table(prevRaw$score))
prev_score$prev <- prev_score$Freq/sum(prev_score$Freq)
colnames(val)

col_maps <- list(c("Multifocal", "multifocal"),
                 c("Large", "large"),
                 c("Endo_moderate_severe", "endo_moderate_severe"),
                 c("Invisible", "invisible"),
                 c("Incomplete", "incomplete"),
                 c("Incomplete_or_invisible", "incomplete_or_invisible"))

out.df <- data.frame()

# Calculate metrics in 2 for loops
# By variable
for(i in 1:length(col_maps)){

  # Get column names
  val_col <- col_maps[[i]][1]
  model_col <- col_maps[[i]][2]

  # Subset to the validation within this strata
  # stratum_data <- val[which(val$score == j), ]
  pos_subset <- val[which(val[[model_col]] == 1), ]
  neg_subset <- val[which(val[[model_col]] == 0), ]

  # Get the prevalence of the LLM answering 'yes'
  prev <- mean(prevRaw[which(!is.na(prevRaw[,model_col])), model_col])

  # --- Part A: Model Predicted TRUE ---
  if (prev > 0 & nrow(pos_subset) > 0) {
    ppv <- mean(pos_subset[[val_col]] == TRUE)
  }

  # --- Part B: Model Predicted FALSE ---
  if (prev <1 & nrow(neg_subset) > 0) {
    npv <- mean(neg_subset[[val_col]] == FALSE)
  }

  # Proportion of the WHOLE POPULATION in this [Model, Truth] cell
  # (Sample Accuracy within stratum) * (Model Positivity in pop within stratum)
  p11 <- max(0, mean(pos_subset[[val_col]] == TRUE), na.rm=T) * prev
  p10 <- max(0, mean(pos_subset[[val_col]] == FALSE), na.rm=T) * prev
  p00 <- max(0, mean(neg_subset[[val_col]] == FALSE), na.rm=T) * (1-prev)
  p01 <- max(0, mean(neg_subset[[val_col]] == TRUE), na.rm=T) * (1-prev)

  # 2. w (Prevalence of model positives for THIS variable in the population)
  # Assume that NA means absence for incomplete resection (usually means it was invisible)
  w_var <- prev

  # Estimated number of TP, TN, FP, FN
  TP_adj <- ppv * w_var * nrow(prevRaw)
  TN_adj <- npv * (1-w_var) * nrow(prevRaw)
  FP_adj <- (1-ppv) * w_var * nrow(prevRaw)
  FN_adj <- (1-npv) * (1-w_var) * nrow(prevRaw)

  # 3. Sensitivity (Using your screenshot formula)
  # Sens = (PPV * w) / (PPV * w + (1 - NPV) * (1 - w))
  sens <- (ppv * w_var) / (ppv * w_var + (1 - npv) * (1 - w_var))

  # 4. Specificity (Using your screenshot formula)
  # Spec = NPV * (1 - w) / (NPV * (1 - w) + (1 - PPV) * w)
  spec <- (npv * (1 - w_var)) / (npv * (1 - w_var) + (1 - ppv) * w_var)

  # 5. F1 Score
  f1 <- (2 * ppv * sens) / (ppv + sens)

  # 6. MCC
  mcc_term1 <- sqrt(ppv * sens * spec * npv)
  mcc_term2 <- sqrt((1 - ppv) * (1 - sens) * (1 - spec) * (1 - npv))
  mcc <- mcc_term1 - mcc_term2

  # 7. Kappa
  po <- ppv*w_var + npv*(1-w_var)
  pe <- ((p11 + p01) * w_var) + ((p00 + p10) * (1-w_var))
  kappa <- (po - pe) / (1 - pe)

  # Store results
  out.df <- rbind(out.df, data.frame("var" = model_col,
                                     "prevalence" = w_var,
                                     "ppv" = ppv, "npv" = npv,
                                     "f1" = f1, "mcc" = mcc,
                                     "accuracy" = ppv*w_var + npv*(1-w_var),
                                     "recall" = sens,
                                     "specificity" = spec,
                                     "kappa" = kappa,
                                     "expected_num_TP" = round(TP_adj),
                                     "expected_num_TN" = round(TN_adj),
                                     "expected_num_FP" = round(FP_adj),
                                     "expected_num_FN" = round(FN_adj)))
}

out <- cbind(out.df[,"var"], round(out.df[,colnames(out.df)!="var"], 3))
colnames(out)[1] <- "variable"
write.csv(out, paste0("./results_", Sys.Date(), ".csv"), row.names=F)

