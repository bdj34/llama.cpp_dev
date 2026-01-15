#!/bin/bash

# Create or truncate the output file
> ~/colonoscopyReport/pos/pos_TIUDocSIDs.txt

# Loop through all files matching *output* in the first level of dir1
for file in ~/results_tmp/colonoscopyReport/yesNo/*output*; do
  # Check if it's a regular file
  if [ -f "$file" ]; then
    # Process the file - search for "Yes" and extract the second column
    grep -i "Yes" "$file" | cut -f2 | while read sid; do
      # Append each SID to pos.txt
      echo "$sid" >> ~/colonoscopyReport/pos/pos_TIUDocSIDs.txt
    done
  fi
done

echo "Positive matches collected in pos.txt"
