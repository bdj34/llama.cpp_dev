import re
import sys
import csv
from datetime import datetime
import random
import time
import os

os.chdir("/home/vhasdcjohnsb2/colonoscopyReport/yesNo")

notes_file = 'colonoscopyReports.csv'

# Define headers for CSVs
notes_headers = ["PatientICN", "EntryDateTime", "TIUDocumentSID", "ReportText"]

# Load notes
csv.field_size_limit(sys.maxsize)
notes = []
with open(notes_file, "r", encoding="utf-8-sig") as f:
    reader = csv.reader(f)
    for row in reader:
        note = dict(zip(notes_headers, row))
        notes.append(note)


print(notes[0])
start_time = time.time()

inputs = []
sids = []

counter = 1
for note in notes:
    sid = note["TIUDocumentSID"]
    report_text = note["ReportText"].replace("\r\n", "\n").replace("\r", "\n")
    full_text = report_text + "\n>>>\n\nIs the text above a colonoscopy report?"
    inputs.append(full_text.replace("\n", "\\n"))
    sids.append(sid)


    counter += 1
    if counter % 100000 == 0:
        print(f"Processed {counter} notes...")
        execution_time = time.time() - start_time
        print(f"Running time from start: {execution_time:.2f} seconds")


# Write outputs
with open("TIUDocSIDs.txt", "w", encoding="utf-8") as f:
    f.writelines(f"{sid}\n" for sid in sids)

with open("input.txt", "w", encoding="utf-8") as f:
    f.writelines(f"{input_str}\n" for input_str in inputs)
