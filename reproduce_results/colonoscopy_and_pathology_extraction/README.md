# IBD Clinical Data Extraction Pipeline

This repository contains the pipeline designed to extract clinically relevant data from pathology and colonoscopy reports using SQL/R/python-based filtering and Large Language Models (LLMs). 

### A. Pathology Report Identification & Organization
* **Step 1: Identify Relevant Reports (`step1_...sql`):** Filters the pathology domain for reports containing anatomical terms related to the colon and rectum. It further restricts results to reports containing dysplasia-related keywords (e.g., "lgd", "low grade", "adenoma", "carcinoma") in the microscopic or diagnosis sections.
* **Step 2: Organize Full Text (`step2_...sql`):** Links pathology report IDs to the full-text note from `NoteTable`. For reports missing a full-text note, it reconstructs a "pseudo-report" by joining separate segments (Specimen, Gross Description, Microscopic, and Diagnosis) from specific 'Pathology Domain' tables.
* **Step 3: Prepare LLM Inputs (`step3_...R`):** Formats pathology text for LLM inference by converting carriage returns, escaping newlines, and saving as .txt files. 

### B. Pathology Classification (dysplasiaClassifier)
* **Step 4: Run Llama-3.3-70B (`step4_...sh`):** Executes structured data extraction from pathology reports using the `llama.cpp` inference engine. It utilizes a GBNF grammar to ensure the model outputs specific fields asked for by the prompt (e.g., dysplasia grade, lesion type).
* **Step 5: Aggregate Classifications (`step5_...R`):** Consolidates the raw LLM outputs into a structured CSV. It standardizes metrics, such as converting measurements from mm to cm and determining if lesions were reported as aggregate or single samples.

### C. Colonoscopy Report Identification/Filtering
* **Step 6: Filter by Document Definition (`step6_...sql`):** Identifies potential colonoscopy reports by matching `TIUDocumentDefinition` titles against a comprehensive whitelist of gastrointestinal-related procedure titles and keyword patterns (e.g., "%gastro%", "%endoscop%"). Keywords were added to the given list (NEEDS CITATION) to prioritize sensitivity because the next steps narrow down the set of possible colonoscopy reports. 
* **Step 7: Extract Putative IBD Reports (`step7_...sql`):** Refines the colonoscopy list by ensuring the patient is in the IBD cohort and the report occurs within a 30-day window of a colonoscopy CPT code or pathology specimen date. It applies a final keyword filter to ensure the note body contains relevant procedural terms.

### D. Colonoscopy Report Validation (yes/no) and Whitelisting
* **Step 8: Generate Validation Inputs (`step8R_...R` or `step8Py...py`):** Prepares the putative reports for a secondary LLM validation step by appending the prompt: *"Is the text above a colonoscopy report?"*. Python And R scripts execute the same logic but python is faster.
* **Step 9: Run Phi-4 Inference (`step9_...sh`):** Uses the `phi-4-14B` model to perform binary classification (Yes/No) on the validity of the colonoscopy reports.
* **Step 10: Aggregate Validation Results (`step10_...R`):** Collects the Phi-4 outputs and generates a "positive" whitelist of validated colonoscopy NoteIDs (saved as CSV: "phi_output_YN_positive_2025_04_10.csv") for use in later steps (step 15+).
* **Step 11: Filter Positive Reports (`step11_...sh`):** Parses the output from the yes/no colonoscopy report LLM inference (Phi-4, step 9). It extracts the NoteIDs of documents confirmed as "Yes" (valid colonoscopy reports) and creates a whitelist for downstream processing.
* **Step 12: Process Validated Notes (`step12_...py`):** Filters the `colonoscopyReports.csv` from step 7 against the validated NoteID whitelist (step 11) to prepare clean inputs for the unlinked extraction (step 13).

### E. Unlinked Colonoscopy Extraction
* **Step 13: Mistral Inference - Unlinked (`step13_...sh`):** Executes structured extraction on confirmed colonoscopy reports using the Mistral-Small-24B model. This step uses a specific system prompt and GBNF grammar to extract general procedural details (e.g., bowel prep quality, extent and severity of colitis) into JSON format.
* **Step 14: Aggregate Unlinked Results (`step14_...R`):** Consolidates the JSON outputs from Mistral into a structured dataframe and merges them with patient identifiers (PatientICN) and procedure dates for downstream processing (step 20).

### F. Path-Colo Report Linkage
* **Step 15: Temporal Linkage Logic (`step15_...R`):** Links validated colonoscopy reports to pathology dysplasia classifier results based on PatientID. It uses a ±30-day window and prioritizes the two reports closest to the specimen date if multiple notes exist. It then formats a "linked" input where the colonoscopy text is appended with structured JSON data from the pathology report.
* **Step 16: SQL Integration (`step16_...sql`):** Imports the linked dataset into the SQL environment for permanent storage and exports a final CSV (`colo_path_linked.csv`) for the high-fidelity extraction phase.
* **Step 17: Prepare Linked Inputs (`step17_...py`):** Processes the `colo_path_linked.csv` to format the integrated text for LLM inference by escaping newlines, organizing the data by `PathologyReportID`, and saving as .txt files.

### G. Linked Colonoscopy/Pathology Extraction
* **Step 18: Mistral Inference - Linked (`step18_...sh`):** Performs specimen-level extraction with Mistral-Small-24B for specimens identified in the pathology report extraction (**B**). This focuses on linking endoscopic findings (e.g., size, morphology, completeness of resection) directly to specific pathology samples.
* **Step 19: Aggregate Linked Results (`step19_...R`):** Structures the JSON output from the linked analysis, ensuring all clinical fields (e.g., `sample_ID`, `location`, `morphology`) are correctly mapped back to their respective PathologyReportIDs.

### H. Final Data Structuring
* **Step 20: Final Data Consolidation (`step20_...R`):** The final stage that merges all previous outputs -- Pathology (**B**), Unlinked extraction (**E**), and Linked extraction (**G**) -- into a single, comprehensive table. It calculates final metrics like converted sizes (min/max size in cm). 
* **Step 21: Add Colonoscopy Report Date (`step21_...sql`):** Joins the master results table back to the original `NoteTable` to ensure every colonoscopy report has an `EntryDateTime`, even if it was not linked to a specific pathology report.

---

## Technical Specifications

| Component | Details |
| :--- | :--- |
| **SQL Environment** | MS SQL Server |
| **R Libraries** | `VINCI`, `DBI`, `jsonlite`, `stringdist`, `ggplot2`, `pbapply` |
| **Inference Engine** | `llama.cpp` (merged from main repo on: [2025-01-29](https://github.com/bdj34/llama.cpp_dev/releases/tag/20250129)) |
| **Pathology Report Extraction Model (step 4)** | [`Llama-3.3-70B-Instruct-Q6_K.gguf`](https://huggingface.co/bartowski/Llama-3.3-70B-Instruct-GGUF/tree/main/Llama-3.3-70B-Instruct-Q6_K) |
| **Validation (yes/no) of Colonoscopy Reports Model (step 9)** | [`phi-4-Q6_K_L.gguf (14B)`](https://huggingface.co/bartowski/phi-4-GGUF/blob/main/phi-4-Q6_K_L.gguf) |
| **Colonoscopy Report Extraction Model (steps 13 & 18)** | [`Mistral-Small-24B-Instruct-2501-Q8_0.gguf`](https://huggingface.co/bartowski/Mistral-Small-24B-Instruct-2501-GGUF/blob/main/Mistral-Small-24B-Instruct-2501-Q8_0.gguf)  |
| **Linkage Window** | ±30 days (Specimen taken date [pathology] vs. Colonoscopy report note date) |

---

## Reproducibility Notes
* **GBNF Grammars and system prompts:** Steps 4, 9, 13, and 18 rely on specific system prompts and grammar files which can be found in the 'system_prompts' and 'grammars' directories. System prompts are specific to the training format of the model (e.g., 'phi4' vs 'llama3' vs. 'mistral'). Specific system prompts and grammars used are identified in the '.sh' script used to run the models.
