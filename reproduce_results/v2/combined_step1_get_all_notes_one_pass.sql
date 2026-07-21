use <DATABASE>;

-- Guard against a stuck/ambient transaction. Some clients default
-- IMPLICIT_TRANSACTIONS ON, which leaves a transaction open after every
-- statement; the full-text TVF and SELECT INTO / columnstore builds
-- then fail with an "active transaction" error. Clear it first.
SET NOCOUNT ON;
SET IMPLICIT_TRANSACTIONS OFF;
IF @@TRANCOUNT > 0 ROLLBACK;

-- =====================================================================
-- ONE-PASS NOTE PULL -- SETUP + SEARCHES (run once in SSMS)
--
-- Workflow (2 files):
--   1. THIS FILE (run once): cohort table, then ONE combined search,
--      persisted to a narrow NoteID master table. Searches return
--      narrow rows and completed fine historically (6.6M NoteIDs in the
--      original IBD_diagnosis run) -- it is the ReportText pull that
--      blows up, so only that gets windowed.
--   2. combined_step1_pull_notes.R: loops NoteDateTime windows (the
--      per-window text-pull query is inlined there as build_query())
--      and writes the notes out.
--
-- Do NOT window the search -- the FullTextSearch TVF (CONTAINSTABLE-
-- like) scans the whole full-text index per call, so a windowed search
-- costs N times the scans for no benefit.
--
-- No per-concept flags: Python assigns concepts per note via regex
-- (mirroring the terms below) when it cuts snippets, so computing flags
-- in SQL would just duplicate that. Downstream, each pipeline keeps a
-- note if its concept regex yields >= 1 snippet.
--
-- CONTAINSTABLE syntax notes (applied to the terms below):
--   * Custom proximity requires double parens:
--       NEAR((term1, term2), maxdist, order). The old form
--       NEAR(t1, t2, 10, TRUE) parses as generic NEAR and silently
--       ignores the distance/order args -- so the corrected queries
--       are STRICTER than the originals ran as.
--   * Prefix terms must be quoted: "crohn*", "hartmann*".
--   * "u.c." / "c.u.c." removed: the word breaker strips punctuation
--     and single letters are stoplist words, so those phrases cannot
--     match the index. "U.C." in documents is indexed with acronym
--     alternate "uc", which the "uc" term already catches. (Catch
--     literal-dot forms with regex in the python snippet step if
--     they matter.)
--   * "j-pouch": hyphen tokenization varies, so "jpouch" is ORed in.
--   * Only prefix (trailing) wildcards exist -- no "*colectomy".
--
-- Downstream, Python assigns each note to pipeline(s) by regex on the
-- pulled text (no flags stored here): IBD_diagnosis, IBD_diagnosis_year,
-- colonoscopy_timing, colectomy, CRC_from_free_text.
-- =====================================================================

-- ---------------------------------------------------------------
-- Step 0: cohort
-- ---------------------------------------------------------------
drop table if exists <SCHEMA>.notePull_cohort;
select coh.PatientID
into <SCHEMA>.notePull_cohort
from <SCHEMA>.Cohort as coh
join <SCHEMA>.baseTable_with_llms as base
	on coh.PatientID = base.PatientID;
create clustered columnstore index cci on <SCHEMA>.notePull_cohort;

-- ---------------------------------------------------------------
-- Step 1: all note IDs for the cohort, built ONCE.
-- Doing this ahead of time speeds up every text search below.
-- ---------------------------------------------------------------
drop table if exists #patNotes;
select notes.NoteID, notes.NoteDateTime, p.PatientID
into #patNotes
from <SCHEMA>.NoteTable as notes
join <SCHEMA>.notePull_cohort as p
	on p.PatientID = notes.PatientID;
create clustered columnstore index cci on #patNotes;

-- ---------------------------------------------------------------
-- Step 2: ONE combined FullTextSearch -- union of every concept's terms
-- in a single SELECT DISTINCT INTO. (Earlier this was split into per-
-- group inserts, but the search was never the bottleneck -- the issue
-- was writing to a permanent table vs a #temp; point matchingNotes_all
-- at a location you can write to.) DISTINCT dedups; concept groups are
-- separated by blank lines only -- NO comments inside the quotes, since
-- anything there is passed to the full-text parser and errors.
--
-- A note is pulled if it matches anything; Python assigns the concept(s)
-- per note via regex anchors that mirror these terms. No per-concept
-- flags are stored here.
--
-- Recall-tuned for LLM phenotyping (LLM does the precision), so this
-- casts a wide net. Notes on the choices:
--   * Prefer explicit phrases over NEAR for multiword ENTITIES that have
--     a canonical form ("ulcerative colitis", cancer phrasings) -- NEAR
--     added little there. NEAR is kept ONLY for organ + resect*/remov*
--     pairs, where "resection of the colon" / "colon was resected"
--     word-order flexibility is what drives recall.
--   * Prefix wildcards ("colonoscop*", "-ectom*", "sigmoidoscop*")
--     catch plurals/adjectives.
--   * Redundancy removed: NEAR(colonoscopy, findings) is subsumed by
--     "colonoscop*"; "flexible sigmoidoscopy" by "sigmoidoscop*"; the
--     -ectomy variants (procto-, hemi-, etc.) are NOT prefixes of
--     "colectom*" so they stay.
--   * Meds are IBD-specific proxies only. Deliberately EXCLUDED:
--     infliximab/adalimumab/azathioprine/methotrexate (heavy non-IBD
--     use in RA, psoriasis, transplant would balloon volume).
--   * Noisy abbreviations (apr, lar, sbr, "colon ca") and broad terms
--     ("colonic mass", "stoma") are IN by design -- Python does the
--     careful filtering.
--   * Dotted acronyms (u.c., c.u.c., ibd-u) still can't be indexed
--     (word breaker splits on punctuation, single letters are stopwords)
--     -- recovered in Python regex, not here.
--
-- CRC note-level "AND NOT" negation is intentionally DROPPED: it can't
-- be scoped to only the CRC terms inside one OR'd query without
-- wrongly excluding non-CRC notes. Screening/surveillance negation is
-- handled at snippet level in Python instead.
-- ---------------------------------------------------------------
drop table if exists <SCHEMA>.matchingNotes_all;

-- SELECT ... INTO creates matchingNotes_all with the source column
-- types; DISTINCT gives one row per NoteID. Concept groups are split by
-- blank lines only -- no comments inside the quotes. The full term
-- rationale (bare colitis/ileitis catch qualifiers + some non-IBD forms
-- filtered in Python; -ectom* variants aren't prefixes of "colectom*";
-- NEAR kept only for organ + resect*/remov*; dotted acronyms recovered
-- in Python) is documented in the Step 2 header above.
select distinct pt.PatientID, pt.NoteDateTime, pt.NoteID
into <SCHEMA>.matchingNotes_all
from <SCHEMA>.FullTextSearch('
"crohn*" OR "chrohn*" OR "chrons" OR "chrones"
OR "colitis" OR "proctitis" OR "proctocolitis" OR "sigmoiditis" OR "ileitis" OR "enteritis"
OR "ileocolitis" OR "pancolitis" OR "proctosigmoiditis"
OR "ibdu" OR "inflammatory bowel disease" OR "ibd" OR "uc" OR "cuc"
OR "mesalamine" OR "mesalazine" OR "sulfasalazine" OR "balsalazide" OR "olsalazine"
OR "asacol" OR "pentasa" OR "lialda" OR "apriso" OR "delzicol"
OR "vedolizumab" OR "entyvio" OR "ustekinumab" OR "stelara"

OR "colonoscop*" OR "sigmoidoscop*" OR "chromoendoscop*" OR "pouchoscop*"
OR "lower endoscopy" OR "flex sig"

OR "colectom*" OR "proctocolectom*" OR "hemicolectom*" OR "sigmoidectom*"
OR "rectosigmoidectom*" OR "proctectom*" OR "ileocecectom*"
OR NEAR((colon, "resect*"), 10, FALSE) OR NEAR((colon, "remov*"), 10, FALSE)
OR NEAR((rectum, "resect*"), 10, FALSE) OR NEAR((rectum, "remov*"), 10, FALSE)
OR NEAR((rectal, "resect*"), 10, FALSE) OR NEAR((rectal, "remov*"), 10, FALSE)
OR NEAR((ileocecal, "resect*"), 10, FALSE) OR NEAR((ileocecal, "remov*"), 10, FALSE)
OR NEAR((bowel, "resect*"), 10, FALSE)
OR "anterior resection" OR "abdominoperineal" OR "apr" OR "lar" OR "sbr" OR "hartmann*"
OR "ileostom*" OR "colostom*" OR "stoma" OR "anastomos*"
OR "ileoanal" OR "ileo anal" OR "ileorectal" OR "ileal pouch" OR "pouch construction"
OR "j-pouch" OR "jpouch" OR "ipaa" OR "kock pouch"
OR "takedown" OR "ostomy reversal"

OR "crc" OR "mcrc" OR "colon ca" OR "rectal ca" OR "metastatic colorectal"
OR NEAR(("colon*", cancer), 10, FALSE) OR NEAR((colorectal, cancer), 10, FALSE)
OR NEAR(("rect*", cancer), 10, FALSE) OR NEAR((sigmoid, cancer), 10, FALSE)
OR NEAR(("cec*", cancer), 10, FALSE) OR NEAR((transverse, cancer), 10, FALSE)
OR NEAR((flexure, cancer), 10, FALSE) OR NEAR((descending, cancer), 10, FALSE)
OR NEAR((ascending, cancer), 10, FALSE)
OR NEAR(("colon*", "carcinom*"), 10, FALSE) OR NEAR((colorectal, "carcinom*"), 10, FALSE)
OR NEAR(("rect*", "carcinom*"), 10, FALSE) OR NEAR((sigmoid, "carcinom*"), 10, FALSE)
OR NEAR(("cec*", "carcinom*"), 10, FALSE) OR NEAR((transverse, "carcinom*"), 10, FALSE)
OR NEAR((flexure, "carcinom*"), 10, FALSE) OR NEAR((descending, "carcinom*"), 10, FALSE)
OR NEAR((ascending, "carcinom*"), 10, FALSE)
OR NEAR(("colon*", "adenoca*"), 10, FALSE) OR NEAR((colorectal, "adenoca*"), 10, FALSE)
OR NEAR(("rect*", "adenoca*"), 10, FALSE) OR NEAR((sigmoid, "adenoca*"), 10, FALSE)
OR NEAR(("cec*", "adenoca*"), 10, FALSE) OR NEAR((transverse, "adenoca*"), 10, FALSE)
OR NEAR((flexure, "adenoca*"), 10, FALSE) OR NEAR((descending, "adenoca*"), 10, FALSE)
OR NEAR((ascending, "adenoca*"), 10, FALSE)
OR NEAR(("colon*", "malignan*"), 10, FALSE) OR NEAR((colorectal, "malignan*"), 10, FALSE)
OR NEAR(("rect*", "malignan*"), 10, FALSE) OR NEAR((sigmoid, "malignan*"), 10, FALSE)
OR NEAR(("cec*", "malignan*"), 10, FALSE) OR NEAR((transverse, "malignan*"), 10, FALSE)
OR NEAR((flexure, "malignan*"), 10, FALSE) OR NEAR((descending, "malignan*"), 10, FALSE)
OR NEAR((ascending, "malignan*"), 10, FALSE)
OR NEAR(("colon*", "neoplas*"), 10, FALSE) OR NEAR((colorectal, "neoplas*"), 10, FALSE)
OR NEAR(("rect*", "neoplas*"), 10, FALSE) OR NEAR((sigmoid, "neoplas*"), 10, FALSE)
OR NEAR(("cec*", "neoplas*"), 10, FALSE) OR NEAR((transverse, "neoplas*"), 10, FALSE)
OR NEAR((flexure, "neoplas*"), 10, FALSE) OR NEAR((descending, "neoplas*"), 10, FALSE)
OR NEAR((ascending, "neoplas*"), 10, FALSE)

OR "dysplas*" OR "hgd" OR "lgd" OR "intraepithelial neoplasia" OR "dalm"
OR "adenoma*" OR "serrated" OR "polyp*"') as search
join #patNotes as pt on pt.NoteID = search.NoteID;

-- Indexes for the windowed text pull: NoteID for the join, NoteDateTime
-- for the window filter. NoteID is unique after DISTINCT.
create unique clustered index uq_noteid on <SCHEMA>.matchingNotes_all(NoteID);
create nonclustered index ix_notedate on <SCHEMA>.matchingNotes_all(NoteDateTime);

-- ---------------------------------------------------------------
-- Step 3: matched-note volume per year -> pick R window size
-- ---------------------------------------------------------------
select year(NoteDateTime) as yr, count(*) as nNotes
from <SCHEMA>.matchingNotes_all
group by year(NoteDateTime)
order by yr;
