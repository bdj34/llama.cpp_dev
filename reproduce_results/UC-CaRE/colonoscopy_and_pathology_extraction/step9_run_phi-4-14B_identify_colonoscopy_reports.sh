#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2025_01_29/build/bin/llama-data-extraction -m ./models_gguf/phi-4-Q6_K_L.gguf \
--grammar-file ~/llama.cpp_2025_01_29/grammars/yesNo.gbnf \
--outDir ~/results_tmp/colonoscopyReport/yesNo \
--sequences $(wc -l < ~/colonoscopyReport/yesNo/input.txt) \
--n-gpu-layers 99 --ctx-size 32768 \
--batch-size 2048 \
--IDfile ~/colonoscopyReport/yesNo/NoteIDs.txt \
--file ~/colonoscopyReport/yesNo/input.txt \
--temp 0 -fa --promptFormat phi4 \
--systemPromptFile ~/llama.cpp_2025_01_29/system_prompts/phi4/YN_colonoscopyReport.txt \
--parallel 4 -sm none -mg 0

