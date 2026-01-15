#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2025_01_29/build/bin/llama-data-extraction -m ./models_gguf/Mistral-Small-24B-Instruct-2501-Q8_0.gguf \
--grammar-file ~/llama.cpp_2025_01_29/grammars/coloReport_unlinked.gbnf \
--outDir ~/results_tmp/colonoscopyReport/pos/ \
--sequences $(wc -l < ~/colonoscopyReport/pos/input_firstHalf_tail.txt) \
--n-gpu-layers 99 --ctx-size 65536 \
--batch-size 2048 \
--IDfile ~/colonoscopyReport/pos/TIUDocSIDs_firstHalf_tail.txt \
--file ~/colonoscopyReport/pos/input_firstHalf_tail.txt \
--temp 0 -fa --promptFormat mistral \
--systemPromptFile ~/llama.cpp_2025_01_29/system_prompts/mistral/coloReport_unlinked_JSON.txt \
--parallel 4 -sm none -mg 0

