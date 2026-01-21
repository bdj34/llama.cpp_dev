#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2024_12_28/build/bin/llama-data-extraction -m ./models_gguf/gemma-2-9B-SPPO_f16.gguf \
--grammar-file ~/llama.cpp_2024_12_28/grammars/IBD_year.gbnf \
--outDir ~/results_tmp/ibdYear \
--sequences $(wc -l < ~/ibdYear/input.txt) \
--n-gpu-layers 99 --ctx-size 65536 \
--IDfile ~/ibdYear/ptIDs.txt \
--file ~/ibdYear/input.txt \
--temp 0 -fa --promptFormat gemma2 \
--systemPromptFile ~/llama.cpp_2024_12_28/system_prompts/gemma2/IBD_year.txt \
--parallel 4 -sm none -mg 0

