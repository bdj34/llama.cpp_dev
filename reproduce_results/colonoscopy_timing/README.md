# Colonoscopy Timing & Confirmation Pipeline

This directory details the pipeline used to identify valid colonoscopy procedures and their dates. This process integrates free-text extraction with structured data (CPT codes and pathology reports) to create a comprehensive timeline of colonoscopy events.

### Overview

The pipeline prioritizes structured data (CPT codes and pathology reports) while using LLMs to fill in gaps where structured data is missing. In our case, this missingness was likely due to colonoscopies performed outside of the VA that are not captured by VA structured data.

1.  **Colonoscopy date extraction:** LLMs extract colonoscopy dates from clinical notes.
2.  **Check against structured data:** LLM-derived dates are checked against structured CPT codes.
    * If an LLM date matches a CPT date (within 60 days), the CPT date is used (high confidence).
    * If there is no CPT match, the LLM date is retained *only* if there is consensus among LLMs.
3.  **Consolidation:** All sources (Pathology, CPT, LLM-only) are merged into a single timeline, collapsing dates that are close together to represent single distinct procedures.

---

### Step-by-Step Pipeline

1.  **Cohort & Note Selection (`step1_get_ibd_pts_colonoscopy_notes.sql`):**
    * Selects patients from the IBD cohort.
    * Uses SQL Full-Text Search to find clinical notes containing the specific term "colonoscopy".
    * Exports these notes to CSV for processing in the next step.

2.  **Text Pre-processing (`step2_process_colonoscopy.py`):**
    * Scans notes for regex patterns indicating a colonoscopy event (e.g., "recent colonoscopy", "colonoscopy performed on").
    * Extracts relevant text snippets (matching lines plus 2 lines before/after).
    * Aggregates snippets into prompt(s) for each patient. Patient may have multiple prompts to ensure we capture all potential colonoscopy instances.

3.  **LLM Inference (Parallel Extraction):**
    * Three different LLMs independently process the text to extract the **Year**, **Month**, and **Site (internal vs. external)** of the colonoscopy.
    * **Phi-4-14B** (`step3A_run_phi4.sh`)
    * **Gemma-2-9B-SPPO** (`step3B_run_gemma2.sh`)
    * **Mistral-Small-24B** (`step3C_run_mistral.sh`)

4.  **LLM Results Aggregation (`step4A_...R` & `step4B_...R`):**
    * Parses the raw output from all three models.
    * **Validation against CPT:** Checks if the extracted LLM date aligns with a known CPT code date within 60 days. If yes, it tags the event as supported by CPT.
    * **Unmatched events:** If no CPT match exists, it checks for cross-model agreement (e.g., "both Gemma and Phi found this date").
    * Outputs a combined file (`results_ibd_colonoscopy_timing...csv`) with the aggregated results.

5.  **Functional Phenotype Creation (`step5_...sql`):**
    * Merges the LLM-derived data with the "Gold Standard" CPT tables.
    * Creates a `finalPheno` table that includes both IBD and non-IBD matched cohorts.
    * Prioritizes CPT dates over LLM dates when duplicates exist.

6.  **Final Timeline Consolidation (`step6_aggregate_colonoscopies...R`):**
    * Integrates a third data source, **Pathology Reports**.
    * Runs a "collapse dates" algorithm to merge events that are likely the same procedure (e.g., a path report on Jan 2nd and a CPT code on Jan 4th are treated as one event).
    * **Date Priority Window:**
        * Pathology & CPT are merged if within **15 days**.
        * LLM & structured data source are merged if within **60 days**.
    * Produces the final master table `finalPheno_colonoscopy_timing` used for analysis.

---

## Technical Specifications

| Component | Details |
| :--- | :--- |
| **Models** | [Phi-4-14B (Quantization: Q6_K_L)](https://huggingface.co/bartowski/phi-4-GGUF/blob/main/phi-4-Q6_K_L.gguf), [Gemma-2-9B-SPPO (F16)](https://huggingface.co/UCLA-AGI/Gemma-2-9B-It-SPPO-Iter3), [`Mistral-Small-24B-Instruct-2501-Q8_0.gguf`](https://huggingface.co/bartowski/Mistral-Small-24B-Instruct-2501-GGUF/blob/main/Mistral-Small-24B-Instruct-2501-Q8_0.gguf) |
| **Data Sources** | Unstructured Notes (LLM), CPT Codes (Structured), Pathology Reports (Structured, dates only) |
| **Matching Logic** | LLM $\leftrightarrow$ CPT (60-day window); Path $\leftrightarrow$ CPT (15-day window) |
| **Consensus** | Unmatched LLM dates require multi-model agreement or high confidence to be retained. |