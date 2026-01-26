# Colectomy-aware CRC & HGD aggregation

This directory contains the logic for creating the final functional phenotypes for invasive colorectal cancer (CRC) and advanced neoplasia (AN; High-Grade Dysplasia [HGD] and/or CRC). 

This pipeline integrates data from LLMs from free text (see dir `reproduce_results/CRC_from_free_text`), LLMs applied to pathology reports (see dir `reproduce_results/colonoscopy_and_pathology_extraction`), "Oncology Domain" data (i.e., the VA cancer registry), and ICD Codes. Cancer/advanced neoplasia dates of diagnosis are then harmonized with nearby colectomy procedure dates, especially in cases where the LLM extracts approximate dates for colectomy and/or CRC/AN. 

### Step-by-Step Pipeline

1.  **Initial Phenotyping (SQL):**
    * **Invasive CRC (`step1A_...sql`):** Aggregates data specifically for invasive adenocarcinoma (T1-T4, N1-N2). It creates a preliminary timeline prioritizing dates from structured data.
    * **Advanced neoplasia (AN; HGD & CRC) (`step1B_...sql`):** Does the same for the broader phenotype that includes high-grade dysplasia (HGD) and carcinoma in-situ, alongside invasive cancer.

2.  **Colectomy Integration & Location Assignment (`step2A_...R` & `step2B_...R`):**
    * Loads the HGD/CRC phenotypes from step 1 and the colectomy phenotypes (see dir `reproduce_results/colectomy_ascertainment`).
    * **Date Logic:**
        * If diagnosis is *after* colectomy, it checks for closeness.
        * Sets HGD/CRC date equal to colectomy date when the dates are close. Here, the definition of 'close' depends on the precision of the data source (30 days for structured data sources all the way to 'within the same year' for LLM-based abstractions).
    * **Location Logic:** Scans data sources within 30 days of the diagnosis date to extract the tumor site.
    * Writes final tables `colectomy_aware_crc...` and `colectomy_aware_hgd_crc...` to SQL.

---

## Technical Specifications

| Component | Details |
| :--- | :--- |
| **Phenotypes** | **Invasive CRC** (Adenocarcinoma T1+) & **HGD/CRC** |
| **Data Hierarchy** | Pathology & Oncology Domain > LLM Free Text & ICD Codes |
| **Location Logic** | Extracts anatomical site (e.g., Rectum, Ascending) from OncDomain > Path > ICD |
