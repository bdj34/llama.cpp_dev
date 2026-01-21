#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2024_12_28/build/bin/llama-data-extraction -m ./models_gguf/Llama-3.3-70B-Instruct-Q6_K-00001-of-00002.gguf \
--grammar-file ~/llama.cpp_2024_12_28/grammars/IBD_year.gbnf \
--outDir ~/results_tmp/ibdYear \
--sequences $(wc -l < ~/ibdYear/disputed_input.txt)  \
--n-gpu-layers 99 --ctx-size 65536 \
--IDfile ~/ibdYear/disputed_ptIDs.txt \
--file ~/ibdYear/disputed_input.txt \
--temp 0 -fa --promptFormat llama3 \
--systemPromptFile ~/llama.cpp_2024_12_28/system_prompts/llama3/IBD_year.txt \
--parallel 4

