import re
import sys
import csv
from datetime import datetime
import random
import time
import os

os.chdir("/home/vhasdcjohnsb2/nonIBD_colonoscopyReport/linked")

notes_file = 'colo_path_linked.csv'

# Define headers for CSVs
notes_headers = ["SurgicalPathologySID", "InputText"]

# Load notes
csv.field_size_limit(sys.maxsize)
notes = []
with open(notes_file, "r", encoding="utf-8-sig") as f:
    reader = csv.reader(f)
    for row in reader:
        note = dict(zip(notes_headers, row))
        notes.append(note)

start_time = time.time()

inputs = []
sids = []

counter = 1
for note in notes:
    sid = note["SurgicalPathologySID"]
    report_text = note["InputText"].replace("\r\n", "\n").replace("\r", "\n")
    inputs.append(report_text.replace("\n", "\\n"))
    sids.append(sid)


    counter += 1
    if counter % 100000 == 0:
        print(f"Processed {counter} notes...")
        execution_time = time.time() - start_time
        print(f"Running time from start: {execution_time:.2f} seconds")


# Write outputs
with open("SurgPathSIDs.txt", "w", encoding="utf-8") as f:
    f.writelines(f"{sid}\n" for sid in sids)

with open("input.txt", "w", encoding="utf-8") as f:
    f.writelines(f"{input_str}\n" for input_str in inputs)