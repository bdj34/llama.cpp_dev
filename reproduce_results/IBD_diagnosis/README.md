# IBD diagnosis type

The process of determining which patients have Inflammatory Bowel Disease colitis more generally and ulcerative colitis specifically proceeds in many steps. Each step is associated with a script in this directory. As an overview, these steps are:
1. Initial filter for individuals with at least 1 ICD code for IBD-colitis. Note regular expression filter to find relevant notes for those patients.
2. Sectioning each patient's notes into smaller blocks of text which match regular expressions and other rules. The python script creates one input per person combining that patient's note sections.
3. Feed each patient's input to each small LLM and have the LLMs each separately determine the diagnosis. LLMs used were [Phi-4-14B (Quantization: Q6_K_L)](https://huggingface.co/bartowski/phi-4-GGUF/blob/main/phi-4-Q6_K_L.gguf) and [Gemma-2-9B-SPPO (Quantization: F16)](https://huggingface.co/UCLA-AGI/Gemma-2-9B-It-SPPO-Iter3). 
4. Process the small LLM outputs to determine when they agree and when they disagree. If they disagree on whether a patient should be included in the IBD-colitis cohort, save the Patient's ID so we know to run it again.
5. Python script to subset the LLM inputs only to those patients where the first 2 small LLMs disagreed.
6. Run [Llama-3.3-70B (Quantization: Q6_K)](https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/tree/main/Llama-3.3-70B-Instruct-Q6_K) to determine the diagnosis of the patients that the small LLMs disagreed on.
7. Process all three LLM outputs to determine the final diagnosis.
