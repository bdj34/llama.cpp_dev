# UC-CaRE

This directory shows how we applied the original [UC-CaRE model (PMID: 33990383](https://pubmed.ncbi.nlm.nih.gov/33990383/) [DOI: 10.1136/gutjnl-2020-323546](https://gut.bmj.com/content/71/4/705), Webtool: https://www.uc-care.uk/) in the Veterans Affairs (VA) electronic health record (EHR). This directory documents the details of the implementation in our work in press (DOI coming soon). We will show the full pipeline from pre-processing, inference, post-processing, and calculating metrics to assess the performance of these steps. 

As an overview, applying the UC-CaRE model required many steps of phenotyping, as detailed below. Each of these is detailed under this directory, using publicly available LLMs and the code available in this GitHub repo:
1. Build a cohort of individuals with Ulcerative Colitis (UC). See 'IBD_diagnosis' directory.
2. Determine the first instance of low grade dysplasia (LGD) for each patient, if it occurs. Determine if the LGD was distal to the known historical colitis extent. Extract all relevant information about each LGD diagnosis, including size, completeness of resection, whether the LGD was 'invisible', the level of endoscopic inflammation at LGD diagnosis, and multifocality (were multiple distinct LGDs diagnosed on the same colonoscopy?).
3. Determine when and if each patient was diagnosed with advanced neoplasia (high grade dysplasia [HGD] or colorectal cancer [CRC]). Exclude patients whose diagnosis of advanced neoplasia is before or at the same time as their first LGD diagnosis.
4. Determine when and if each patient had a colectomy. Exclude patients who had colectomy before or at the same time as their first LGD diagnosis.

Previously, all of these steps had to be done manually for each patient. This directory contains our implementation of an automated extraction of these details. 