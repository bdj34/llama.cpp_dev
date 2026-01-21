#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2024_12_28/build/bin/llama-data-extraction -m ./models_gguf/phi-4-Q6_K_L.gguf \
--grammar-file ~/llama.cpp_2024_12_28/grammars/IBD_year.gbnf \
--outDir ~/results_tmp/ibdYear \
--sequences $(wc -l < ~/ibdYear/input.txt) \
--n-gpu-layers 99 --ctx-size 65536 \
--IDfile ~/ibdYear/ptIDs.txt \
--file ~/ibdYear/input.txt \
--temp 0 -fa --promptFormat phi4 \
--systemPromptFile ~/llama.cpp_2024_12_28/system_prompts/phi4/IBD_year.txt \
--parallel 4 -sm none -mg 1

