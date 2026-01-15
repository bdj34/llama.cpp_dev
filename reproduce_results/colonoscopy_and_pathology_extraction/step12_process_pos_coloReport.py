import re
import sys
import csv
from datetime import datetime
import random
import time
import os

os.chdir("~/colonoscopyReport/pos")

notes_file = 'colonoscopyReports.csv'

# Define headers for CSVs
notes_headers = ["PatientID", "EntryDateTime", "NoteID", "ReportText"]

# Read in the positive whitelisted NoteIDs
whitelist_IDs = set()
with open("pos_NoteIDs.txt", "r", encoding = "utf-8") as f:
    for line in f:
        whitelist_IDs.add(line.strip())

# Load notes
csv.field_size_limit(sys.maxsize)
notes = []
with open(notes_file, "r", encoding="utf-8-sig") as f:
    reader = csv.reader(f)
    for row in reader:
        note = dict(zip(notes_headers, row))
        if note["NoteID"] in whitelist_IDs:
            notes.append(note)

if notes:
    print(notes[0])
else: 
    print("No matching IDs found")
    
start_time = time.time()

inputs = []
IDs = []

counter = 1
for note in notes:
    ID = note["NoteID"]
    report_text = note["ReportText"].replace("\r\n", "\n").replace("\r", "\n")
    inputs.append(report_text.replace("\n", "\\n"))
    IDs.append(ID)


    counter += 1
    if counter % 100000 == 0:
        print(f"Processed {counter} notes...")
        execution_time = time.time() - start_time
        print(f"Running time from start: {execution_time:.2f} seconds")


# Write outputs
with open("NoteIDs.txt", "w", encoding="utf-8") as f:
    f.writelines(f"{ID}\n" for ID in IDs)

with open("input.txt", "w", encoding="utf-8") as f:
    f.writelines(f"{input_str}\n" for input_str in inputs)
