#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

~/llama.cpp_2025_01_29/build/bin/llama-data-extraction -m ./models_gguf/Llama-3.3-70B-Instruct-Q6_K-00001-of-00002.gguf \
--grammar-file ~/llama.cpp_2025_01_29/grammars/dysplasiaClassifier.gbnf \
--outDir ~/results_tmp/dysplasiaClassifier \
--sequences $(wc -l < ~/dysplasiaClassifier/input.txt) \
--n-gpu-layers 99 --ctx-size 65536 \
--IDfile ~/dysplasiaClassifier/PathologyReportIDs.txt \
--file ~/dysplasiaClassifier/input.txt \
--temp 0 -fa --promptFormat llama3 \
--systemPromptFile ~/llama.cpp_2025_01_29/system_prompts/llama3/dysplasiaClassifier.txt \
--parallel 4

