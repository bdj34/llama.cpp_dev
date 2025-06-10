import re
import sys
import csv
from datetime import datetime
import random
import time
import os

os.chdir("/home/vhasdcjohnsb2/ibdYear/lateAddIBD")

notes_file = 'ibdYear_notes.csv'

# Parameters
myregex = (
    r"(?i)((crohn|ulcerative\s+colitis|\buc\b|\bu\.c\.\b|\bcuc\b|\bc\.u\.c\.\b|"
    r"inflammatory\s+bowel\s+disease|\bibd\b|ulcerative\s+proct|chronic\s+colitis|"
    r"chronic\s+proct).{0,30}?((\b\d{2}\b)|(\b\d{4}\b)))|"
    r"(((\b\d{2}\b)|(\b\d{4}\b)).{0,30}?(crohn|ulcerative\s+colitis|\buc\b|\bu\.c\.\b|\bc\.u\.c\.\b|"
    r"\bcuc\b|inflammatory\s+bowel\s+disease|\bibd\b|ulcerative\s+proct|chronic\s+colitis|"
    r"chronic\s+proct))"
)
priorityregex = (
    r"(?i)((crohn|ulcerative\s+colitis|\buc\b|\bu\.c\.\b|\bcuc\b|\bc\.u\.c\.\b|"
    r"inflammatory\s+bowel\s+disease|\bibd\b|ulcerative\s+proct|chronic\s+colitis|"
    r"chronic\s+proct).{0,30}?((19|20)\d{2}))|"
    r"(((19|20)\d{2}).{0,30}?(crohn|ulcerative\s+colitis|\buc\b|\bu\.c\.\b|\bc\.u\.c\.\b|"
    r"\bcuc\b|inflammatory\s+bowel\s+disease|\bibd\b|ulcerative\s+proct|chronic\s+colitis|"
    r"chronic\s+proct))"
) 
icdIgnore = (
    r"(?i)(556|555|K52|K51|K50|ICD|snomed)"
)

lines_before = 2 # Don't change context based on # of notes
lines_after = 2
excerpt_limit = 30
n_most_recent = 3
n_most_distant = 15
max_excerpts_per_note = 10

# Define headers for CSVs
notes_headers = ["PatientICN", "EntryDateTime", "TIUDocumentSID", "ReportText"]

# Load notes
csv.field_size_limit(sys.maxsize)
notes = []
notes_count = {}
with open(notes_file, "r", encoding="utf-8-sig") as f:
    reader = csv.reader(f)
    for row in reader:
        note = dict(zip(notes_headers, row))
        notes.append(note)
        patient_icn = note["PatientICN"]
        if patient_icn in notes_count:
            notes_count[patient_icn] += 1
        else:
            notes_count[patient_icn]=1

print(notes[0])
start_time = time.time()

# Extract context lines based on regex (for a single note)
def merge_indices(indices, last_line, expand_before, expand_after):
    if not indices:
        return []
    indices.sort()
    merged = [[indices[0] - expand_before, indices[0] + expand_after]]

    for idx in indices[1:]:
        if idx - merged[-1][1] <= expand_before + expand_after:
            merged[-1][1] = idx + expand_after # Combine blocks if close enough
        else:
            merged.append([idx - expand_before, idx + expand_after]) # Otherwise, make new block

    # Make sure the starts and ends of blocks are within the note
    return [[max(0, start), min(last_line, end)] for start, end in merged]

excerpts = {}
seen_text = {}
priority_matches = {} # Save the patient's priority matches
counter = 1
for note in notes:
    patient_icn = note["PatientICN"]
    report_text = note["ReportText"].replace("\r\n", "\n").replace("\r", "\n")
    if(note["EntryDateTime"] == "NULL"):
        counter += 1 
        continue # Skip notes with NULL date
    else:
        entry_date = datetime.strptime(note["EntryDateTime"], "%Y-%m-%d %H:%M:%S").strftime("%Y-%m")

    matches = [
        (m.start(), m.end())
        for m in re.finditer(myregex, report_text, flags=re.IGNORECASE)
    ]

    if not matches:
        counter += 1
        continue
    
    # Split by new lines
    lines = report_text.split("\n")
    # Get the number of the character where the new line starts
    line_offsets = [0] + [len(line) + 1 for line in lines]
    line_offsets = [sum(line_offsets[:i + 1]) for i in range(len(line_offsets))]

    # Get all lines that are a part of a match (allowing matches to span lines)
    match_lines = {
        line
        for start, end in matches
        for line in range(
            max(0, next(i for i in range(len(line_offsets) - 1) if line_offsets[i] > start) - 1),
            next(i for i in range(len(line_offsets) - 1) if line_offsets[i] >= end)
        )
    }
    
    # Get the blocks to be used for snippets/excerpts from lines
    blocks = merge_indices(
        sorted(match_lines),
        len(lines),
        lines_before,
        lines_after
    )
    
    # Create patient dict if doesn't exist
    if patient_icn not in excerpts:
        excerpts[patient_icn] = []
        seen_text[patient_icn] = set()
        priority_matches[patient_icn] = 0
    
    # Add an excerpt to the patient dict
    for start, end in blocks[:max_excerpts_per_note]:  # Limit excerpts per note, prioritize beginning of note
        
        # Get excerpt
        excerptText = "\n".join(lines[start:end+1])

        # Check if its an ICD code
        excludeMatch = bool(re.search(icdIgnore, excerptText, flags=re.IGNORECASE)) 
        
        # Check if its a priority match
        priorityMatch = bool(re.search(priorityregex, excerptText, flags=re.IGNORECASE))

        # Don't add if exact excerpt is already included
        if excerptText.strip().lower() in seen_text[patient_icn]:
            continue
        
        # Don't add if its text from ICD/SNOMED
        if excludeMatch:
            continue

        seen_text[patient_icn].add(excerptText.strip().lower())

        # If priority match, insert in front and increment priority_matches count
        if priorityMatch:
            priority_matches[patient_icn] += 1
            excerpts[patient_icn].insert(0, 
                f"\n<<<\nNote date (YYYY-MM): {entry_date}\nNote text:\n"
                + excerptText
                + "\n>>>\n"
            )
        else:
            excerpts[patient_icn].append(
                f"\n<<<\nNote date (YYYY-MM): {entry_date}\nNote text:\n"
                + excerptText
                + "\n>>>\n"
            )

    counter += 1
    if counter % 100000 == 0:
        print(f"Processed {counter} notes...")
        execution_time = time.time() - start_time
        print(f"Running time from start: {execution_time:.2f} seconds")
        #print(excerpts[patient_icn])

# Aggregate excerpts by patient
inputs = []
icns = []
for patient_icn, patient_excerpts in excerpts.items():

    if len(patient_excerpts) <= excerpt_limit:
        patient_excerpts.sort()
        patient_string = "".join(patient_excerpts)
        patient_string = patient_string + "\nQuestion: When was this patient originally diagnosed with IBD (Ulcerative colitis or Crohn's disease)?\n"
    else:
        priority_excerpts = patient_excerpts[0:priority_matches[patient_icn]]
        patient_excerpts = patient_excerpts[priority_matches[patient_icn]:]
        patient_excerpts.sort()
        most_recent_excerpts = patient_excerpts[-n_most_recent:]
        most_distant_excerpts = patient_excerpts[:n_most_distant]
        n_included = len(set(priority_excerpts + most_recent_excerpts + most_distant_excerpts))

        # Adjust what is included based on number of priority excerpts
        if n_included < excerpt_limit and len(patient_excerpts[n_most_distant:-n_most_recent]) > 0:
            # Randomly select excerpts until excerpt_limit is reached
            random_excerpts = random.sample(patient_excerpts[n_most_distant:-n_most_recent], 
                    excerpt_limit-n_included)
        elif n_included == excerpt_limit: # Don't add random excerpts (perfect amount as is)
            random_excerpts = []
        elif len(priority_excerpts) < excerpt_limit: # Choose randomly from most recent and distant
            recent_distant = list(set(most_recent_excerpts + most_distant_excerpts))
            random_excerpts = random.sample(recent_distant, 
                    min(excerpt_limit - len(priority_excerpts), len(recent_distant)))
            most_recent_excerpts = []
            most_distant_excerpts = []
        else: # Priority excerpts >= excerpt limit, select random excerpt_limit
            random_excerpts = random.sample(priority_excerpts, excerpt_limit)
            priority_excerpts = []
            most_recent_excerpts = []
            most_distant_excerpts = []
            
        all_excerpts = list(set(priority_excerpts + most_recent_excerpts + 
            random_excerpts + most_distant_excerpts))
        all_excerpts.sort()
        patient_string = "".join(all_excerpts)
        patient_string = patient_string + "\nQuestion: When was this patient originally diagnosed with IBD (Ulcerative colitis or Crohn's disease)?\n"
        
    # Replace newline characters with \\n
    inputs.append(patient_string.replace("\n", "\\n"))
    icns.append(patient_icn)

# Write outputs
with open("ptIDs.txt", "w", encoding="utf-8") as f:
    f.writelines(f"{icn}\n" for icn in icns)

with open("input.txt", "w", encoding="utf-8") as f:
    f.writelines(f"{input_str}\n" for input_str in inputs)
