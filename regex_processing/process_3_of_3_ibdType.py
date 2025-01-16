import re
import sys
import csv
from datetime import datetime
import random
import time
import os

os.chdir("/home/vhasdcjohnsb2/ibdType_CSVs_2025_01_08")

notes_file = 'ibdType_notes_group3_of_3.csv'

# Parameters
myregex = (
    r"(?i)crohn|ulcerative\s+colitis|"
    r"(for|of|vs\.|vs|with|hx|dx|c\/w|mild|active|severe|moderate|chronic)\s+(\buc\b|\bu\.c\.\b)|"
    r"\bcuc\b|\bc\.u\.c\.\b|inflammatory\s+bowel\s+disease|"
    r"\bibd\b|ulcerative\s+proct|chronic\s+colitis|chronic\s+proct|"
    r"colonosc.*\bfindings"
)

lines_before_max = 30
lines_before_min = 3
lines_after = 3
notes_threshold = 5
excerpt_limit = 15
n_most_recent = 5
max_excerpts_per_note = 15

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
counter = 1
for note in notes:
    patient_icn = note["PatientICN"]
    report_text = note["ReportText"].replace("\r\n", "\n").replace("\r", "\n")
    if(note["EntryDateTime"] == "NULL"):
        counter += 1 
        continue # Skip notes with NULL date
    else:
        entry_date = datetime.strptime(note["EntryDateTime"], "%Y-%m-%d %H:%M:%S").strftime("%Y-%m-%d")

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
        lines_before_max if notes_count[patient_icn] <= notes_threshold else lines_before_min,
        lines_after
    )
    
    # Create patient dict if doesn't exist
    if patient_icn not in excerpts:
        excerpts[patient_icn] = []
    
    # Add an excerpt to the patient dict
    for start, end in blocks[:max_excerpts_per_note]:  # Limit excerpts per note, prioritize beginning of note
        excerpts[patient_icn].append(
            f"\n<<<\nNote date (YYYY-MM-DD): {entry_date}\nNote text:\n"
            + "\n".join(lines[start:end + 1])
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
    patient_excerpts.sort()

    if len(patient_excerpts) <= excerpt_limit:
        # If the number of excerpts is within the limit, concatenate all
        patient_string = "".join(patient_excerpts)
    else:
        most_recent_excerpts = patient_excerpts[-n_most_recent:]
        # Randomly select excerpts until excerpt_limit is reached
        random_excerpts = random.sample(patient_excerpts[:-n_most_recent], excerpt_limit-n_most_recent)
        all_excerpts = most_recent_excerpts + random_excerpts
        all_excerpts.sort()
        patient_string = "".join(all_excerpts)
        
    # Replace newline characters with \\n
    inputs.append(patient_string.replace("\n", "\\n"))
    icns.append(patient_icn)

# Write outputs
with open("ptIDs_3_of_3.txt", "w", encoding="utf-8") as f:
    f.writelines(f"{icn}\n" for icn in icns)

with open("input_3_of_3.txt", "w", encoding="utf-8") as f:
    f.writelines(f"{input_str}\n" for input_str in inputs)
