# Validation of LLM-based Risk Factor Extraction

This directory contains the data and code used to validate the performance of the Large Language Model (LLM) in extracting the specific clinical risk factors required for the UC-CaRE model.

### Overview

The validation process assesses how accurately the LLM extracts the four binary risk factors (**Multifocal**, **Large**, **Inflammation**, **Incomplete/Invisible**) from pathology and colonsocopy reports.

1.  **Manual Review:** A subset of patients was manually reviewed to establish ground truth labels. From this subset, we calculate the Positive Predictive Value (PPV) and Negative Predictive Value (NPV) of the LLM. Due to their relative rarity, high risk patients were up-sampled so that the set which underwent manual review had more of the high risk index LGDs than would be found in the a truly random sample. 
    * The raw data required to reproduce these results are the following 2 CSVs:
    * **`deID_prevalence_for_github_2026-01-26.csv`:** Contains the binary model outputs for the full cohort. Used to calculate the frequency ($w$) of positive predictions in the real-world population.
    * **`deID_reviewed_subset_for_github_2026-01-26.csv`:** Contains the paired data (Manual Review vs. Model Prediction) for the validation subset.
        * Capitalized columns (e.g., `Multifocal`) represent the manually review ground truth. 
        * Lower case columns (e.g., `multifocal`) represent the model result.
2.  **Prevalence Adjustment (`get_extraction_validation_metrics.R`):** We calculate the apparent prevalence ($w$: the rate at which the LLM predicts "Positive") across the entire cohort for each variable. Then, using the PPV/NPV and the apparent prevalence $w$, we calculate the population-level **Sensitivity**, **Specificity**, **Accuracy**, and **F1 Score**. This ensures the metrics reflect the model's performance on the full dataset, not just the up-sampled validation set.
3. Results are stored in the CSV `/UC-CaRE/variable_extraction_validation/results_2026-01-26.csv`.

---

## Technical Specifications

| Component | Details |
| :--- | :--- |
| **Variables Validated** | Multifocal, Large (≥1cm), Moderate/Severe Inflammation, Incomplete or Invisible, Incomplete (independently), Invisible (independently) |
| **Key Metrics** | PPV, NPV, Sensitivity, Specificity, F1, Matthews Correlation Coefficient (MCC), Cohen's Kappa |
| **Input Data** | De-identified yes/no outputs for full cohort and reviewed subset |
