import os

os.chdir("/home/vhasdcjohnsb2/ibdType_CSVs_2025_01_08")

def filter_files(included_ids_file):
    # Read included IDs
    with open(included_ids_file, 'r') as f:
        included_ids = set(line.strip() for line in f if line.strip())

    filtered_ptids = []
    filtered_inputs = []

    # Process each group
    for group in range(1, 4):
        
        input_file = "input_" + str(group) + "_of_3.txt"
        ptid_file = "ptIDs_" + str(group) + "_of_3.txt"

        # Read ptIDs and input lines
        with open(ptid_file, 'r') as f:
            ptids = [line.strip() for line in f if line.strip()]
        with open(input_file, 'r') as f:
            inputs = [line.strip() for line in f if line.strip()]

        # Ensure ptIDs and inputs have the same length
        if len(ptids) != len(inputs):
            print(f"Error: ptIDs and inputs mismatch in group {group}.")
            continue

        # Filter based on included IDs
        for ptid, input_line in zip(ptids, inputs):
            if ptid in included_ids:
                filtered_ptids.append(ptid)
                filtered_inputs.append(input_line)

    # Write filtered results to new files
    with open("disputed_ptIDs.txt", 'w') as f:
        f.write("\n".join(filtered_ptids) + "\n")
    with open("disputed_input.txt", 'w') as f:
        f.write("\n".join(filtered_inputs) + "\n")

# Parameters
included_ids_file = "disputedICNs_for_llama70B.txt"  # Replace with the file containing included IDs

# Run the script
filter_files(included_ids_file)
