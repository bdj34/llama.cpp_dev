#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2025_01_29/build/bin/llama-data-extraction -m ./models_gguf/Mistral-Small-24B-Instruct-2501-Q8_0.gguf \
--grammar-file ~/llama.cpp_2025_01_29/grammars/colo_path_linked.gbnf \
--outDir ~/results_tmp/colonoscopyReport/linked \
--sequences $(wc -l < ~/colonoscopyReport/linked/input.txt) \
--n-gpu-layers 99 --ctx-size 65536 \
--batch-size 2048 \
--IDfile ~/colonoscopyReport/linked/PathologyReportIDs.txt \
--file ~/colonoscopyReport/linked/input.txt \
--temp 0 -fa --promptFormat mistral \
--systemPromptFile ~/llama.cpp_2025_01_29/system_prompts/mistral/colo_path_linked.txt \
--parallel 4 -sm none -mg 0
