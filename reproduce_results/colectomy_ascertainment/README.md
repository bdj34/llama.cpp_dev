# Colectomy Identification & Timing

This directory details the pipeline for identifying colectomy procedures and extracting their dates from clinical notes. This process uses a multi-model LLM consensus approach, integrating results from four Large Language Models (LLMs) and structured CPT data.

### Overview of Logic

1.  **Extraction:** Four LLMs independently scan pre-processed clinical notes to identify if a colectomy occurred and extract the procedure date, type, and segments removed.
2.  **Consensus:** A hierarchical consensus algorithm determines the most accurate date from the LLM outputs.
    * **Llama-3.3-70B** is the primary reference.
    * High confidence is assigned when Llama agrees with 2 or more other models.
    * Lower confidence is assigned when models disagree or only approximate matches are found.
3.  **Integration:** The best LLM date is compared against CPT codes.
    * **Priority:** CPT dates are generally preferred as the gold standard.
    * **Override:** LLM dates override CPT dates only if the CPT date is missing OR if the LLM is Certain/High confidence and the dates differ by >2 years (suggesting the CPT might be for a different event or missing the primary surgery).

---

### Step-by-Step Pipeline

1.  **Cohort & Note Selection (`step1_get_ibd_pts_colectomy_notes.sql`):**
    * Filters for IBD patients.
    * Uses SQL Full-Text Search to find notes with terms like "colectomy", "proctectomy", "sigmoidectomy", "ileostomy", or "J-pouch".
    * Exports relevant notes to `colectomy_notes.csv`.

2.  **Text Pre-processing (`step2_process_colectomy.py`):**
    * Scans notes for regex patterns related to colon/rectal removal.
    * Extracts relevant snippets (context window: 2 lines before/after).
    * Aggregates up to 20 snippets per patient, always including the 5 most recent and 5 earliest snippets.
    * Appends the specific question: *"Has this patient had all or part of their colon or rectum removed?"*

3.  **LLM Inference (Quad-Model Extraction):**
    * Four models run in parallel to extract: **Yes/No**, **Procedure Type**, **Segments Removed**, **Month**, and **Year**.
    * **Phi-4-14B** (`step3A_run_phi4.sh`)
    * **Gemma-3-27B** (`step3B_run_gemma3.sh`)
    * **Llama-3.3-70B** (`step3C_run_llama70.sh`)
    * **Mistral-Small-24B** (`step3D_run_mistral.sh`)

4.  **Results Aggregation & Consensus (`step4A_...R` & `step4B_...R`):**
    * Parses raw outputs from all four models.
    * **Consensus Logic:**
        * **Certain:** Llama + 3 others agree on year.
        * **High:** Llama + 2 others agree on year.
        * **Medium:** Llama + 1 other agrees on year.
        * **Low-Medium:** Llama is within 2 years of another model.
        * **Low:** All models say "Yes", but years disagree significantly.
    * **Deduplication:** Sorts procedures to prioritize more specific surgeries and clean dates.
    * **Final Integration with CPT:**
        * Merges LLM consensus results with CPT data.
        * Outputs the final table `ibd_colectomy_results...` containing the first valid colectomy date, source (LLM vs CPT), and confidence level.

---

## Technical Specifications

| Component | Details |
| :--- | :--- |
| **Models** | [Llama-3.3-70B (Q6_K)](https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF), [Phi-4-14B (Q6_K_L)](https://huggingface.co/bartowski/phi-4-GGUF), [Gemma-3-27B (Q6_K_L)](https://huggingface.co/bartowski/gemma-3-27b-it-GGUF), [Mistral-Small-24B (Q8_0)](https://huggingface.co/bartowski/Mistral-Small-24B-Instruct-2501-GGUF) |
| **Data Sources** | Unstructured Notes (LLM), CPT Codes (Structured) |
| **Extraction Logic** | Regex-based snippet prioritization (up to 20 excerpts/patient) |
