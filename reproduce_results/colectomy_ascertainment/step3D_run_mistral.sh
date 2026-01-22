#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2025_01_29/build/bin/llama-data-extraction -m ./models_gguf/Mistral-Small-24B-Instruct-2501-Q8_0.gguf \
--grammar-file ~/llama.cpp_2025_01_29/grammars/colectomy.gbnf \
--outDir ~/results_tmp/colectomy \
--sequences $(wc -l < ~/colectomy/input.txt) \
--n-gpu-layers 99 --ctx-size 65536 \
--IDfile ~/colectomy/ptIDs.txt \
--file ~/colectomy/input.txt \
--temp 0 -fa --promptFormat mistral \
--systemPromptFile ~/llama.cpp_2025_01_29/system_prompts/mistral/colectomy.txt \
--parallel 4 -sm none -mg 1
