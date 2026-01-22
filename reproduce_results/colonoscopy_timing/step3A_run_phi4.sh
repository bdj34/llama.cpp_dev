#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2025_01_29/build/bin/llama-data-extraction -m ./models_gguf/phi-4-Q6_K_L.gguf \
--grammar-file ~/llama.cpp_2025_01_29/grammars/colonoscopy.gbnf \
--outDir ~/results_tmp/colonoscopy \
--sequences $(wc -l < ~/colonoscopy/input.txt) \
--n-gpu-layers 99 --ctx-size 65536 \
--IDfile ~/colonoscopy/ptIDs.txt \
--file ~/colonoscopy/input.txt \
--temp 0 -fa --promptFormat phi4 \
--systemPromptFile ~/llama.cpp_2025_01_29/system_prompts/phi4/colonoscopy.txt \
--parallel 4 -sm none -mg 1

