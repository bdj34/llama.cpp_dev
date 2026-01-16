# Reproducing LLM-based phenotyping

In this directory, I document how we used this repository in addition to structured data sources to create phenotypes for our Inflammatory Bowel Disease (IBD) colitis cohort. This includes many distinct tasks:
* **Cohort building**
    * **IBD:** Identifying individuals with IBD-colitis, including Ulcerative Colitis (UC), Crohn's colitis, and IBD-Unclassified (IBD-U).
    * **non-IBD:** An age, sex, race and ethnicity matched cohort of individuals without IBD. 
Then, within these cohorts, we performed downstream LLM-based phenotyping:
* **IBD diagnosis date:** Many individuals had IBD diagnosis dates that pre-date the structured data. We use clinical notes (e.g., "UC diagnosed in 1996 ...") to identify the true diagnosis date. 
* **Cancer ascertainment:** In the Veterans Affairs (VA) healthcare system, previous work in prostate cancer ([DOI: 10.1200/CCI.21.00030](https://doi.org/10.1200/cci.21.00030)) has shown that many cancer cases are not well captured by structured data. We use LLMs to identify additional cases of colorectal cancer (CRC) that may not be captured well in structured data. 
* **Colonoscopy and pathology extraction:** Sample-specific extraction that uses both pathology and colonoscopy reports to get critical features known to be predictive of CRC risk (e.g., visible lesion size, completeness of resection, etc.). Also extracts general colonoscopy findings like endoscopic colitis severity/extent, bowel prep score, landmarks reached, and others. 
* **Colonoscopy timing:** Because many individuals seek care outside the VA, we need to know when individuals are seen for external colonoscopies that would not be captured with VA structured data. While we can't access data from these colonoscopies, it helps us to know what we don't know. 
* **Colectomy ascertainment:** For similar reasons as those listed above, many colectomies are not captured in structured data. Colectomy data is especially important in the study of cancer because it alters risk and is a common exclusion criteria. Colectomy as an outcome is also important because many CRC risk factors (e.g., severe colitis) are also risk factors for colectomy. 

# UC-CaRE specific analysis
Many of the phenotypes listed above are used downstream for the UC-CaRE validation. Some of the extracted phenotypes required additional processing scripts to be converted to binary variables for UC-CaRE. These scripts are include in the UC-CaRE directory. 
