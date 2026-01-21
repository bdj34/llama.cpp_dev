#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2025_03_17/build/bin/llama-data-extraction -m ./models_gguf/gemma-3-27b-it-Q6_K_L.gguf \
--grammar-file ~/llama.cpp_2025_03_17/grammars/crc_free_text.gbnf \
--outDir ~/results_tmp/crc_free_text/rerun \
--sequences $(wc -l < ~/crc_free_text/ptIDs_eitherPos.txt) \
--n-gpu-layers 99 --ctx-size 65536 \
--IDfile ~/crc_free_text/ptIDs_eitherPos.txt \
--file ~/crc_free_text/input_eitherPos.txt \
--temp 0 -fa --promptFormat gemma2 \
--systemPromptFile ~/llama.cpp_2025_03_17/system_prompts/gemma2/crc_free_text.txt \
--parallel 1 

