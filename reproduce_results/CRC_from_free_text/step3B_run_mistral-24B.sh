#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2025_01_29/build/bin/llama-data-extraction -m ./models_gguf/Mistral-Small-24B-Instruct-2501-Q8_0.gguf \
--grammar-file ~/llama.cpp_2025_01_29/grammars/crc_free_text.gbnf \
--outDir ~/results_tmp/crc_free_text \
--sequences $(wc -l < ~/crc_free_text/ptIDs.txt) \
--n-gpu-layers 99 --ctx-size 65536 \
--IDfile ~/crc_free_text/ptIDs.txt \
--file ~/crc_free_text/input.txt \
--temp 0 -fa --promptFormat mistral \
--systemPromptFile ~/llama.cpp_2025_01_29/system_prompts/mistral/crc_free_text.txt \
--parallel 4 -sm none -mg 0

