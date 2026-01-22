# Completeness of Resection

This directory details the pipeline for determining the **completeness of resection** for visible Low-Grade Dysplasia (LGD) lesions found in colonoscopy and pathology reports. This process uses the medical LLM (**medGemma-27B**) to analyze linked pathology and colonoscopy reports and ascertain if a specific lesion was fully removed.

### Step by step

The pipeline focuses specifically on lesions identified as **Low-Grade Dysplasia (LGD)** or **Adenoma** in pathology reports. It links these pathology findings to their corresponding colonoscopy reports to provide full context to the LLM tasked with determining the completeness of resection. Pre-processing relies on data extracted previously in the directory `reproduce_results/colonoscopy_and_pathology_extraction`.

1.  **Cohort Identification and making inputs (`step1A_...R` & `step1B_...R`):**
    * **LGD Filter:** Filters pathology reports to isolate relevant lesions (LGD, adenomas) from previously extracted data while excluding high-grade dysplasia or adenocarcinoma.
    * **Exclusion:** Removes "invisible" lesions (LGD on random biopsies) where resection status is not applicable.
    * **Report Linking:** Links the specific pathology report (and specific sample/jar ID) to the most relevant colonoscopy report(s). If multiple potential colonoscopy reports exist, it prioritizes the one(s) with the most complete extracted data from the first pass (see directory: `colonoscopy_and_pathology_extraction`).
    * **Create inputs:**
        * **Target:** Asks about a specific sample ID (e.g., "Specimen A") or a lesion matching a specific description (if sample ID is missing/unknown).
        * **Context:** Provides the full text of the **Pathology Report** followed by the linked **Colonoscopy Report(s)**.
        * **Question:** *"What is the resection status of specimen X?"*

2.  **LLM Inference (`step2_run_completeness.sh`):**
    * Uses **medGemma-27B (Quantization: Q4KM)**
    * **System Prompt:** `system_prompts/gemma/completenessOfResection.txt`
    * **Grammar:** `grammars/completenessOfResection.gbnf`

3.  **Aggregation (`step3_aggregate_completenessOfResection.R`):**
    * Parses the raw output from the LLM.
    * Extracts the resection status answer.
    * Maps the results back to the `PathologyReportID`, `ColonoscopyReportID`, and `sampleID` for downstream analysis.
    * Saves the final `aggregated_completeness_medGemma_27B_...csv` file.

---

## Technical Specifications

| Component | Details |
| :--- | :--- |
| **Model** | [medGemma-27B-Instruct (Text only. Quantization: Q4KM)](https://huggingface.co/unsloth/medgemma-27b-text-it-GGUF/blob/main/medgemma-27b-text-it-Q4_K_M.gguf) |
| **Data Sources** | Linked Pathology & Colonoscopy Reports + previously extracted LLM data |
| **Target Lesions** | Low-Grade Dysplasia (LGD), Adenomas |
| **Exclusions** | High-Grade Dysplasia, Adenocarcinoma, Random Biopsies ("Invisible" lesions) |
| **Linking Logic** | Path Report $\rightarrow$ Colonoscopy Report (prioritizing notes with more complete data) |