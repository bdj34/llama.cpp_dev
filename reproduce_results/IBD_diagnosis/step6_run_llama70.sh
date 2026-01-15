#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2024_12_28/build/bin/llama-data-extraction -m ./models_gguf/Llama-3.3-70B-Instruct-Q6_K-00001-of-00002.gguf \
--grammar-file ~/llama.cpp_2024_12_28/grammars/ibd_typeOnly.gbnf \
--outDir ~/results_tmp/ibd_type_all \
--sequences 21140 \
--n-gpu-layers 99 --ctx-size 65536 \
--IDfile ~/ibdType_CSVs_2025_01_08/disputed_ptIDs.txt \
--file ~/ibdType_CSVs_2025_01_08/disputed_input.txt \
--temp 0 -fa --promptFormat llama3 \
--systemPromptFile ~/llama.cpp_2024_12_28/system_prompts/llama3/IBD_typeOnly.txt \
--parallel 16

