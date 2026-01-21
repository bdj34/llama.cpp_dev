# Colorectal Cancer (CRC) Diagnosis Extraction from Free Text

This directory contains the pipeline for identifying patients diagnosed with Colorectal Cancer (CRC) and extracting the diagnosis date from unstructured clinical notes. This process is designed to supplement other sources of data which are known to be incomplete.

The pipeline utilizes a multi-stage consensus approach with three Large Language Models (LLMs): **Llama-3.3-70B**, **Mistral-Small-24B**, and **Gemma-3-27B**.

**Overview of the Logic:**
1.  **Broad Initial Sweep:** Two models (Llama-70B and Mistral-24B) initially screen all patients using regex-derived snippets of their clinical notes.
2.  **Targeted Re-Evaluation:** Patients flagged as "Positive" by *either* model in the first sweep are re-processed with expanded context. 
    * **Note:** During this re-run, Mistral receives slightly less context than Llama and Gemma due to its smaller context window limit (32k vs 64k+).
3.  **Strict Consensus:** A final diagnosis is confirmed only if **4 out of 5** model decisions (2 initial + 3 re-runs) agree on a positive diagnosis.

---

### Step-by-Step Pipeline

1.  **Cohort Filtering (`step1_get_relevant_notes.sql`):** * Identifies clinical notes containing terms like "colorectal cancer", "rectal cancer", or "adenocarcinoma" using SQL Full-Text Search.
    * Excludes notes explicitly related to "screening" or "surveillance" to reduce noise.
    * Exports raw text to CSV.

2.  **Initial Text Sectioning (`step2_process_crc_free_text.py`):** * Scans notes for regex matches where cancer terms appear.
    * Extracts snippets with a small context window (5 lines before/after) to fit the initial prompt.
    * Aggregates snippets into a single prompt per patient.

3.  **Initial LLM Inference (Round 1):**
    * **Llama-3.3-70B** (`step3A_run_llama-3.3-70B.sh`) and **Mistral-Small-24B** (`step3B_run_mistral-24B.sh`) process the entire cohort.
    * They determine if the patient has CRC and extract the diagnosis year/month.

4.  **Identify "Either Positive" Cohort (`step4_aggregate_crc_free_text...R`):**
    * Aggregates results from Round 1.
    * Identifies any patient where *at least one* model said "Yes". These patients are flagged for a deeper look.

5.  **Prepare Expanded Inputs (Round 2):**
    * **For Llama & Gemma (`step5B_...py`):** Generates new prompts with significantly more context (20 lines before/15 lines after) and more excerpts (up to 40).
    * **For Mistral (`step5A_...py`):** Generates prompts with moderate context (15 lines before/10 lines after) to accommodate its 32k token limit.

6.  **Re-Run Inference (Round 2):**
    * **Mistral-Small-24B** (`step6A_...sh`) runs on the "Either Positive" cohort with moderate context.
    * **Llama-3.3-70B** (`step6B_...sh`) runs on the "Either Positive" cohort with expanded context.
    * **Gemma-3-27B** (`step6C_...sh`) runs on the same input as Llama-3.3-70B.

7.  **Final Consensus & Date Extraction (`step7_aggregate_crc_free_text...R`):** * **Consensus Rule:** A patient is confirmed as CRC positive only if the sum of positive votes across all 5 decisions (Mistral R1, Llama R1, Mistral R2, Llama R2, Gemma R2) is $\ge$ 4.
    * **Date Consensus:** Calculates the mode of the diagnosis years extracted. If there is a tie, it defaults to the average.
    * **Confidence Scoring:** Assigns High/Medium/Low confidence based on the agreement between models.
    * Writes the final verified cohort and dates to SQL database.

---

## Technical Specifications

| Component | Details |
| :--- | :--- |
| **LLMs run on both inputs** | [`Llama-3.3-70B-Instruct-Q6_K.gguf`](https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/tree/main/Llama-3.3-70B-Instruct-Q6_K) & [`Mistral-Small-24B-Instruct-2501-Q8_0.gguf`](https://huggingface.co/bartowski/Mistral-Small-24B-Instruct-2501-GGUF/blob/main/Mistral-Small-24B-Instruct-2501-Q8_0.gguf) |
| **LLM run on added context only only** | Adds [Gemma-3-27B (Q6_K_L)](https://huggingface.co/bartowski/google_gemma-3-27b-it-GGUF/blob/main/google_gemma-3-27b-it-Q6_K_L.gguf) |
| **Consensus Threshold** | **4 / 5 votes** required for positive diagnosis. |
