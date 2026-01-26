# UC-CaRE webtool validation pipeline

This directory contains the code for validating the [**UC-CaRE (Ulcerative Colitis-Cancer Risk Estimator)**](https://www.uc-care.uk/) clinical prediction model ([Curtius et al., *Gut* 2022](https://doi.org/10.1136/gutjnl-2020-323546)) in Veterans Affairs (VA) national healthcare data. Details about the validation of the LLM-based data extraction from the pathology & colonoscopy reports is shown in the sub-directory `variable_extraction_validation`.

### Step-by-step pipeline

1.  **Data preparation & scoring (`step1A_validate_webtool...R`):** Identifies patients with Ulcerative Colitis and an index Low-Grade Dysplasia (LGD) lesion. This is the main methods section step in the pipeline, where various data sources are integrated to get binary 0/1 (no/yes) answers for the four main UC-CaRE variables (**Large** lesion (≥1cm), **Incomplete/Invisible** lesion, **Multifocal** disease, and **Moderate/Severe Inflammation**) as well as outcomes (CRC, colectomy, etc.).
    * **Inputs:** Fetches data from SQL (Pathology, Colectomy, Colonoscopy Timing, PSC, Smoking).
    * **Logic:** * Links index LGD lesions to colonoscopy reports.
        * Applies `step1B_UCCARE_fns.txt` helper functions to calculate the 4 UC-CaRE risk factors.
        * Determines event/censor dates (AN / CRC vs. colectomy / death / last note).
    * **Outputs:** `UCCaRE_preSurvival_...csv`

2-6. **Plots shown in the paper:** Predictions from UC-CaRE data use the logic in `step3B_calculate_survival...R`.
    * **0-5 Years (`step2_plot_to5yrs...R`):** Generates Kaplan-Meier curves stratified by the number of risk factors (0-4), truncated at 5 years (Fig. 1B).
    * **Bar Charts (`step3A_bar_charts...R`):** * Plots a side-by-side comparison of **Predicted Risk**, **Observed Risk (KM)**, and **Competing Risk (CRR)** at 1 year (Fig. 1C).
    * **0 Risk factor plot (`step4_plot_0_riskFactor...R`):** * Specific visualization for the low-risk group comparing prediction vs. observation (Fig. 1D).
    * **All follow-up (`step5_plot_all_follow-up...R`):** Generates KM curves for the full duration of follow-up (Supp. Fig. 1A).
    * **Calibration curves (`step6_calibration_plots...R`):** Generates calibration curves for **all 16 binary risk profiles** (e.g., `0000` vs `1010`).
        * Plots the model prediction ribbon (black) overlaying the observed KM curve (colored).
        * Includes a "double uncertainty" analysis that accounts for potential misclassification in the confusion matrix.

---

## Technical specifications

| Component | Details |
| :--- | :--- |
| **Risk factors** | 1. **Large** (≥1cm), 2. **Incomplete/Invisible**, 3. **Multifocal**, 4. **Inflammation** (Mod/Severe) |
| **Outcome** | Advanced Neoplasia (HGD or CRC) |
| **Censoring** | Colectomy, Death, Last Clinical Note. Some analyses treat colectomy as competing risk. |
| **Validation method** | Comparison of published model vs. observed Kaplan-Meier and/or competing risks estimates |
