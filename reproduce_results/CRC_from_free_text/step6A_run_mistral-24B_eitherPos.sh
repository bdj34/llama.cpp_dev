#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2025_01_29/build/bin/llama-data-extraction -m ./models_gguf/Mistral-Small-24B-Instruct-2501-Q8_0.gguf \
--grammar-file ~/llama.cpp_2025_01_29/grammars/crc_free_text.gbnf \
--outDir ~/results_tmp/crc_free_text/rerun \
--sequences $(wc -l < ~/crc_free_text/ptIDs_eitherPos_forMistral.txt) \
--n-gpu-layers 99 --ctx-size 32768 \
--IDfile ~/crc_free_text/ptIDs_eitherPos_forMistral.txt \
--file ~/crc_free_text/input_eitherPos_forMistral.txt \
--temp 0 -fa --promptFormat mistral \
--systemPromptFile ~/llama.cpp_2025_01_29/system_prompts/mistral/crc_free_text.txt \
--parallel 1 -sm none -mg 0

