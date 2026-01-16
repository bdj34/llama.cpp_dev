# IBD diagnosis type

This directory contains the end-to-end pipeline for determining Inflammatory Bowel Disease (IBD) diagnosis using a consensus approach with multiple Large Language Models (LLMs).

The LLM part of the process uses the following logic:
* Two efficient smaller models (**Gemma-2-9B-SPPO** and **Phi-4-14B**) process the entire cohort.
* Cases where the smaller models disagree are escalated to a larger model (**Llama-3.3-70B**) to act as the final arbiter.


Including all pre- and post-processing, here's the step-by-step process we used for IBD diagnosis. 
1. **Initial cohort filter (`step1_...sql`):** Initial filter for individuals with at least 1 ICD code for IBD-colitis. Note regular expression filter to find relevant notes for those patients.
2. **Text sectioning (`step2_...py`):***Sectioning each patient's notes into smaller blocks of text which match regular expressions and other rules. The python script creates one input per person combining that patient's note sections.
3. **Small LLM inference (`step3A_...sh` and `step3B_...sh`):** Feed each patient's input to each small LLM and have the LLMs each separately determine the diagnosis. LLMs used were [Phi-4-14B (Quantization: Q6_K_L)](https://huggingface.co/bartowski/phi-4-GGUF/blob/main/phi-4-Q6_K_L.gguf) and [Gemma-2-9B-SPPO (Quantization: F16)](https://huggingface.co/UCLA-AGI/Gemma-2-9B-It-SPPO-Iter3). 
4. **Aggregate small LLM results & identify disagreement (`step4_...R`):** Process the small LLM outputs to determine when they agree and when they disagree. If they disagree on whether a patient should be included in the IBD-colitis cohort, save the Patient's ID so we know to run it with the larger LLM.
5. **Prepare inputs for larger LLM (`step5_...py`):** Python script to subset the LLM inputs only to those patients where the first 2 small LLMs disagreed.
6. **Larger LLM inference (`step6_...sh`):** Run [Llama-3.3-70B (Quantization: Q6_K)](https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/tree/main/Llama-3.3-70B-Instruct-Q6_K) to determine the diagnosis of the patients that the small LLMs disagreed on.
7. **Determine consensus & structure data (`step7_...R`):** Process all three LLM outputs to determine the final diagnosis. Save as CSV and write to SQL table. 

--- 

## Technical Specifications

| Component | Details |
| :--- | :--- |
| **Tier 1 Models** | [Phi-4-14B (Quantization: Q6_K_L)](https://huggingface.co/bartowski/phi-4-GGUF/blob/main/phi-4-Q6_K_L.gguf) & [Gemma-2-9B-SPPO (Quantization: F16)](https://huggingface.co/UCLA-AGI/Gemma-2-9B-It-SPPO-Iter3) |
| **Tier 2 Model** | [Llama-3.3-70B (Quantization: Q6_K)](https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/tree/main/Llama-3.3-70B-Instruct-Q6_K) |
| **Environment** | MS SQL Server, R, Python, `llama.cpp` |
| **Extraction Logic** | Regex-based snippet prioritization (most recent + random) |

---