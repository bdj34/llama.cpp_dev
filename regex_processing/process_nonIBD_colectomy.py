import re
import sys
import csv
from datetime import datetime
import random
import time
import os

os.chdir("/home/vhasdcjohnsb2/nonIBD_colectomy")

notes_file = 'colectomy_notes.csv'

# Parameters
myregex = (
    r"(?i)colectomy|proctectomy|"
    r"(remov|resect).{0,20}?(colo|rect|cecum|sigmoid)|"
    r"(colo|rect|cecum|sigmoid).{0,20}?(remov|resect)|"
    r"hartmann"
)

lines_before_max = 2 # Don't change context based on # of notes
lines_before_min = 2
lines_after = 2
notes_threshold = 0
excerpt_limit = 20
n_most_recent = 5
n_most_distant = 5
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
seen_text = {}
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
        lines_before_max if notes_count[patient_icn] <= notes_threshold else lines_before_min,
        lines_after
    )
    
    # Create patient dict if doesn't exist
    if patient_icn not in excerpts:
        excerpts[patient_icn] = []
        seen_text[patient_icn] = set()
    
    # Add an excerpt to the patient dict
    for start, end in blocks[:max_excerpts_per_note]:  # Limit excerpts per note, prioritize beginning of note
        
        # Get excerpt
        excerptText = "\n".join(lines[start:end+1])
        
        # Don't add if exact excerpt is already included
        if excerptText.strip().lower() in seen_text[patient_icn]:
            continue

        seen_text[patient_icn].add(excerptText.strip().lower())

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
    patient_excerpts.sort()

    if len(patient_excerpts) <= excerpt_limit:
        patient_string = "".join(patient_excerpts)
        patient_string = patient_string + "\nQuestion: Has this patient had all or part of their colon or rectum removed?\n"
    else:
        most_recent_excerpts = patient_excerpts[-n_most_recent:]
        most_distant_excerpts = patient_excerpts[:n_most_distant]
        # Randomly select excerpts until excerpt_limit is reached
        random_excerpts = random.sample(patient_excerpts[n_most_distant:-n_most_recent], excerpt_limit-n_most_recent-n_most_distant)
        all_excerpts = most_recent_excerpts + random_excerpts + most_distant_excerpts
        all_excerpts.sort()
        patient_string = "".join(all_excerpts)
        patient_string = patient_string + "\nQuestion: Has this patient had all or part of their colon or rectum removed?\n"
        
    # Replace newline characters with \\n
    inputs.append(patient_string.replace("\n", "\\n"))
    icns.append(patient_icn)

# Write outputs
with open("ptIDs.txt", "w", encoding="utf-8") as f:
    f.writelines(f"{icn}\n" for icn in icns)

with open("input.txt", "w", encoding="utf-8") as f:
    f.writelines(f"{input_str}\n" for input_str in inputs)
