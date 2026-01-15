# IBD Clinical Data Extraction Pipeline: Phase 1 (Steps 1–10)

This repository contains the first stage of a pipeline designed to identify inflammatory bowel disease (IBD) patients and process their clinical documentation (Pathology and Colonoscopy reports) using SQL-based filtering and Large Language Model (LLM) classification.

## Phase 1 Workflow

### 1. Pathology Report Identification & Organization
* **Identify Relevant Reports (`step1_...sql`):** Filters the pathology domain for reports containing anatomical terms related to the colon and rectum. It further restricts results to reports containing dysplasia-related keywords (e.g., "lgd", "low grade", "adenoma", "carcinoma") in the microscopic or diagnosis sections.
* **Organize Full Text (`step2_...sql`):** Links confirmed pathology IDs to the full-text `NoteTable`. For reports missing a single full-text entry, it reconstructs a "pseudo-report" by joining separate segments (Specimen, Gross Description, Microscopic, and Diagnosis) from specific pathology tables.
* **Prepare LLM Inputs (`step3_...R`):** Formats pathology text for inference by converting carriage returns and escaping newlines. It shuffles the data to ensure an unbiased processing order for the model.

### 2. Dysplasia Classification (Pathology)
* **Run Llama-3.3-70B (`step4_...sh`):** Executes structured data extraction from pathology reports using the `llama.cpp` inference engine. It utilizes a GBNF grammar to ensure the model outputs specific clinical fields (e.g., dysplasia grade, lesion type).
* **Aggregate Classifications (`step5_...R`):** Consolidates the raw LLM outputs into a structured CSV. It calculates additional metrics, such as converting measurements from mm to cm and determining if lesions were reported as aggregate or single samples.

### 3. Colonoscopy Report Identification
* **Filter by Document Definition (`step6_...sql`):** Identifies potential colonoscopy reports by matching `TIUDocumentDefinition` titles against a comprehensive whitelist of over 200 gastrointestinal-related procedure titles and keyword patterns (e.g., "%gastro%", "%endoscop%").
* **Extract Putative IBD Reports (`step7_...sql`):** Refines the colonoscopy list by ensuring the patient is in the IBD cohort and the report occurs within a 30-day window of a colonoscopy CPT code or pathology specimen date. It applies a final keyword filter to ensure the note body contains relevant procedural terms like "cecum", "bowel prep", or "indication".

### 4. Report Validation (Binary Classification) and Whitelisting
* **Generate Validation Inputs (`step8R_...R`):** Prepares the putative reports for a secondary LLM validation step by appending the prompt: *"Is the text above a colonoscopy report?"*.
* **Run Phi-4 Inference (`step9_...sh`):** Uses the `phi-4-14B` model to perform binary classification (Yes/No) on the validity of the colonoscopy reports.
* **Aggregate Validation Results (`step10_...R`):** Collects the Phi-4 outputs and generates a "positive" whitelist of validated colonoscopy NoteIDs for use in the following steps.
* **Filter Positive Reports (`step11_...sh`):** Parses the output from the binary classification model (Phi-4). It extracts the NoteIDs of documents confirmed as "Yes" (valid colonoscopy reports) and creates a whitelist for downstream processing.
* **Process Validated Notes (`step12_...py`):** Filters the original `colonoscopyReports.csv` against the validated NoteID whitelist to prepare clean inputs for the extraction models.

### 5. General Colonoscopy Extraction (Unlinked)
* **Mistral Inference - Unlinked (`step13_...sh`):** Executes structured extraction on confirmed colonoscopy reports using the Mistral-Small-24B model. This step uses a specific system prompt and GBNF grammar to extract general procedural details (e.g., bowel prep quality, extent of colitis) into JSON format.
* **Aggregate Unlinked Results (`step14_...R`):** Consolidates the JSON outputs from Mistral into a structured dataframe and merges them with patient identifiers (PatientICN) and procedure dates for analysis.

### 6. Path-Colo Report Linkage
* **Temporal Linkage Logic (`step15_...R`):** Links validated colonoscopy reports to pathology dysplasia classifier results based on PatientID. It uses a ±30-day window and prioritizes the two reports closest to the specimen date if multiple notes exist. It then formats a "linked" input where the colonoscopy text is appended with structured JSON data from the pathology report.
* **SQL Integration (`step16_...sql`):** Imports the linked dataset into the SQL environment for permanent storage and exports a final CSV (`colo_path_linked.csv`) for the high-fidelity extraction phase.
* **Prepare Linked Inputs (`step17_...py`):** Processes the `colo_path_linked.csv` to format the integrated text for LLM inference by escaping newlines and organizing the data by `PathologyReportID`.

### 7. High-Fidelity Extraction (Linked Analysis)
* **Mistral Inference - Linked (`step18_...sh`):** Performs a "deep dive" extraction on the combined Path-Colo reports using Mistral-Small-24B. This model specifically focuses on linking clinical findings (e.g., size, morphology, completeness of resection) directly to specific pathology samples.
* **Aggregate Linked Results (`step19_...R`):** Collects and validates the JSON output from the linked analysis, ensuring all clinical fields (e.g., `sample_ID`, `location`, `morphology`) are correctly mapped back to their respective PathologyReportIDs.

### 8. Final Synthesis
* **Final Data Consolidation (`step20_...R`):** The final stage that merges all previous outputs—Pathology, Linked extraction, and Unlinked extraction—into a single, comprehensive table. It calculates final metrics like converted sizes (min/max size in cm). 
* **Add Colonoscopy Report Date (`step21_...sql`):** Joins the master results table back to the original `NoteTable` to ensure every colonoscopy report has an `EntryDateTime`, even if it was not linked to a specific pathology report.

---

## Technical Specifications

| Component | Details |
| :--- | :--- |
| **SQL Environment** | MS SQL Server |
| **R Libraries** | `VINCI`, `DBI`, `jsonlite`, `stringdist`, `ggplot2`, `pbapply` |
| **Inference Engine** | `llama.cpp` (merged from main repo on: 2025-01-29) |
| **Validation (yes/no) of Colonoscopy Reports Model** | `phi-4-Q6_K_L.gguf` (14B) |
| **Pathology Report Extraction Model** | `Llama-3.3-70B-Instruct-Q6_K.gguf` |
| **Colonoscopy Report Extraction Model** | `Mistral-Small-24B-Instruct-2501-Q8_0.gguf`  |
| **Linkage Window** | ±30 days (Specimen taken date (pathology) vs. Colonoscopy report note date) |

---

## Reproducibility Notes
* **GBNF Grammars:** Steps 4, 9, 13, and 18 rely on specific system prompts and grammar files which can be found in the 'system_prompts' and 'grammars' directories. System prompts are specific to the class of model (e.g., 'phi4' vs 'llama3' vs. 'mistral'). Specific system prompts and grammars used are identified in the '.sh' script used to run the models.
* **Database Tables:** Final results are persisted to the `<SCHEMA>.ibd_and_nonIBD_path_colo_results_2025_05_12` SQL table.
