#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2025_01_29/build/bin/llama-data-extraction -m ./models_gguf/Llama-3.3-70B-Instruct-Q6_K-00001-of-00002.gguf \
--grammar-file ~/llama.cpp_2025_01_29/grammars/crc_free_text.gbnf \
--outDir ~/results_tmp/crc_free_text/rerun \
--sequences $(wc -l < ~/crc_free_text/ptIDs_eitherPos.txt) \
--n-gpu-layers 99 --ctx-size 98304 \
--IDfile ~/crc_free_text/ptIDs_eitherPos.txt \
--file ~/crc_free_text/input_eitherPos.txt \
--temp 0 -fa --promptFormat llama3 \
--systemPromptFile ~/llama.cpp_2025_01_29/system_prompts/llama3/crc_free_text.txt \
--parallel 2

