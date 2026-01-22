#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2025_03_17/build/bin/llama-data-extraction -m ./models_gguf/gemma-3-27b-it-Q6_K_L.gguf \
--grammar-file ~/llama.cpp_2025_03_17/grammars/colectomy.gbnf \
--outDir ~/results_tmp/colectomy \
--sequences $(wc -l < ~/colectomy/input.txt) \
--n-gpu-layers 99 --ctx-size 32768 \
--IDfile ~/colectomy/ptIDs.txt \
--file ~/colectomy/input.txt \
--temp 0 -fa --promptFormat gemma2 \
--systemPromptFile ~/llama.cpp_2025_03_17/system_prompts/gemma2/colectomy.txt \
--parallel 2 -sm none -mg 0
