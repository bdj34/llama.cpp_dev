import re
import sys
import csv
from datetime import datetime
import random
import time
import os

os.chdir("<PATH>/colonoscopy")

notes_file = 'colonoscopy_notes.csv'

# Parameters
myregex = "(?i)((recent|last|had|\d+)\s+colonoscopy)|(colonoscopy\s+(last|done|at|was|in|on|\d+|performed|report))"

lines_before_max = 2 # No difference based on number of notes
lines_before_min = 2
lines_after = 2
notes_threshold = 0 # Again, no diff based on # of notes
excerpt_limit = 20 # How many excerpts for a given line (patient can have multiple lines)
n_most_recent = float('inf') # Take all most recent
max_excerpts_per_note = 15

# Define headers for CSVs
notes_headers = ["PatientID", "EntryDateTime", "NoteID", "ReportText"]

# Load notes
csv.field_size_limit(sys.maxsize)
notes = []
notes_count = {}
with open(notes_file, "r", encoding="utf-8-sig") as f:
    reader = csv.reader(f)
    for row in reader:
        note = dict(zip(notes_headers, row))
        notes.append(note)
        patient_id = note["PatientID"]
        if patient_id in notes_count:
            notes_count[patient_id] += 1
        else:
            notes_count[patient_id]=1

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

noteDates = {}
excerpts = {}
seen_text = {}
counter = 1
for note in notes:
    patient_id = note["PatientID"]
    report_text = note["ReportText"].replace("\r\n", "\n").replace("\r", "\n")
    if(note["EntryDateTime"] == "NULL"):
        counter += 1 
        continue # Skip notes with NULL date
    else:
        entry_date = datetime.strptime(note["EntryDateTime"], "%Y-%m-%d %H:%M:%S").strftime("%Y")

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
        lines_before_max if notes_count[patient_id] <= notes_threshold else lines_before_min,
        lines_after
    )
    
    # Create patient dict if doesn't exist
    if patient_id not in excerpts:
        excerpts[patient_id] = []
        noteDates[patient_id] = []
        seen_text[patient_id] = set()
    
    # Add an excerpt to the patient dict
    for start, end in blocks[:max_excerpts_per_note]:
        # Get excerpt
        excerptText = "\n".join(lines[start:end+1])

        # Don't add if exact excerpt is already included (even with diff date)
        if excerptText.strip().lower() in seen_text[patient_id]:
            #print("Duplicate text removed")
            continue

        seen_text[patient_id].add(excerptText.strip().lower())
        
        excerpts[patient_id].append(
            f"\n<<<\nNote date (YYYY): {entry_date}\nNote text:\n"
            + excerptText
            + "\n>>>\n"
        )
        noteDates[patient_id].append(note["EntryDateTime"])

    counter += 1
    if counter % 100000 == 0:
        print(f"Processed {counter} notes...")
        execution_time = time.time() - start_time
        print(f"Running time from start: {execution_time:.2f} seconds")
        #print(excerpts[patient_id])

# Aggregate excerpts by patient
inputs = []
ids = []
for patient_id, patient_excerpts in excerpts.items():
    ptDates = noteDates[patient_id]
    patient_excerpts_sorted = [note for _, note in sorted(zip(ptDates, patient_excerpts), key = lambda pair: pair[0])]
    
    for i in range(0, len(patient_excerpts_sorted), excerpt_limit):

        # Take a chunk of N=excerpt_limit excerpts
        excerpt_chunk = patient_excerpts_sorted[i:i+excerpt_limit]

        # Concatenate
        patient_string = "".join(excerpt_chunk)

        # Append to inputs and ids
        inputs.append(patient_string.replace("\n", "\\n"))
        ids.append(patient_id)

# Write outputs
with open("ptIDs.txt", "w", encoding="utf-8") as f:
    f.writelines(f"{id}\n" for id in ids)

with open("input.txt", "w", encoding="utf-8") as f:
    f.writelines(f"{input_str}\n" for input_str in inputs)
