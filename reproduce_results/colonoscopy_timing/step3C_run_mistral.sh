#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2025_01_29/build/bin/llama-data-extraction -m ./models_gguf/Mistral-Small-24B-Instruct-2501-Q8_0.gguf \
--grammar-file ~/llama.cpp_2025_01_29/grammars/colonoscopy.gbnf \
--outDir ~/results_tmp/colonoscopy/ \
--sequences $(wc -l < ~/colonoscopy/ptIDs.txt) \
--n-gpu-layers 99 --ctx-size 32768 \
--IDfile ~/colonoscopy/ptIDs.txt \
--file ~/colonoscopy/input.txt \
--temp 0 -fa --promptFormat mistral \
--systemPromptFile ~/llama.cpp_2025_01_29/system_prompts/mistral/colonoscopy.txt \
--parallel 4 -sm none -mg 0

