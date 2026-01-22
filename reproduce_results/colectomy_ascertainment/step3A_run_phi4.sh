#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2024_12_28/build/bin/llama-data-extraction -m ./models_gguf/phi-4-Q6_K_L.gguf \
--grammar-file ~/llama.cpp_2024_12_28/grammars/colectomy.gbnf \
--outDir ~/results_tmp/colectomy \
--sequences $(wc -l < ~/colectomy/input.txt) \
--n-gpu-layers 99 --ctx-size 65536 \
--IDfile ~/colectomy/ptIDs.txt \
--file ~/colectomy/input.txt \
--temp 0 -fa --promptFormat phi4 \
--systemPromptFile ~/llama.cpp_2024_12_28/system_prompts/phi4/colectomy.txt \
--parallel 4 -sm none -mg 1

