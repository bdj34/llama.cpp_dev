# IBD Diagnosis Year Extraction

This directory contains the end-to-end pipeline for determining the **year of original IBD diagnosis** using a consensus approach with multiple Large Language Models (LLMs). In downstream use cases such as UC-CaRE, the LLM-extracted data from this process was used in combination with other date sources like ICD codes, colitis findings from colonoscopy results, and/or IBD medication data.

The LLM part of the process uses the following logic (analogous to the logic used for IBD diagnosis type):
* Two efficient smaller models (**Gemma-2-9B-SPPO** and **Phi-4-14B**) process the entire cohort.
* Cases where the smaller models disagree on the diagnosis year are escalated to a larger model (**Llama-3.3-70B**).

Including all pre- and post-processing, here's the step-by-step process we used for extracting the IBD diagnosis year. 

1. **Initial note filter (`step1_get_relevant_notes.sql`):** Selects clinical notes for the relevant patient cohort that contain IBD-specific keywords (e.g., "Crohn", "Ulcerative Colitis") using MS SQL Full-Text Search. Saves the raw text to CSV.
2. **Text sectioning & prompt creation (`step2_process_ibdYear.py`):** Scans patient notes for specific patterns where IBD terms appear near date indicators (e.g., "Crohn's diagnosed in 2010"). It prioritizes excerpts with explicit 4-digit or 2-digit years. The script aggregates these excerpts into a single prompt per patient, appending the question: *"When was this patient originally diagnosed with IBD (Ulcerative colitis or Crohn's disease)?"*
3. **Small LLM inference (`step3A_...sh` and `step3B_...sh`):** Feeds each patient's input to the small LLMs to extract the diagnosis year. The models used are [Phi-4-14B (Quantization: Q6_K_L)](https://huggingface.co/bartowski/phi-4-GGUF/blob/main/phi-4-Q6_K_L.gguf) and [Gemma-2-9B-SPPO (Quantization: F16)](https://huggingface.co/UCLA-AGI/Gemma-2-9B-It-SPPO-Iter3). 
4. **Aggregate small LLM results & identify disagreement (`step4_...R`):** Parses the output from Phi and Gemma. It compares the extracted years; if the models disagree, the patient ID and input are saved to a "disputed" list for the larger model.
5. **Larger LLM inference (`step5_run_llama-3.3-70B.sh`):** Runs [Llama-3.3-70B (Quantization: Q6_K)](https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/tree/main/Llama-3.3-70B-Instruct-Q6_K) only on the disputed patients identified in Step 4.
6. **Determine consensus (`step6_...R`):** Merges results from all three models. 
    * **Consensus Logic:** If Llama was run, its answer is prioritized. If Llama was not run (meaning the small models agreed), the agreed-upon year is used.
    * **Normalization:** Converts text answers (e.g., ranges or "During...") into numeric years (e.g., taking the mean of a range).
7. **Finalize data (`step7_...R`):** Joins the final consensus diagnosis year back to the base SQL table and writes the results to the database.

--- 

## Technical Specifications

| Component | Details |
| :--- | :--- |
| **Small LLMs** | [Phi-4-14B (Quantization: Q6_K_L)](https://huggingface.co/bartowski/phi-4-GGUF/blob/main/phi-4-Q6_K_L.gguf) & [Gemma-2-9B-SPPO (Quantization: F16)](https://huggingface.co/UCLA-AGI/Gemma-2-9B-It-SPPO-Iter3) |
| **Large LLM** | [Llama-3.3-70B (Quantization: Q6_K)](https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/tree/main/Llama-3.3-70B-Instruct-Q6_K) |
| **Environment** | MS SQL Server, R, Python, `llama.cpp` |
| **Extraction Logic** | Regex-based snippet prioritization (IBD terms near dates) |
