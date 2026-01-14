#!/bin/bash

set -e # exit on error
set -x # print command before executing

cd ~

# Run Gemma-2 on GPU 0 (-mg 0) and don't split onto the second GPU (-sm none)

~/llama.cpp_2024_12_28/build/bin/llama-data-extraction -m ./models_gguf/phi-4-Q6_K_L.gguf \
--grammar-file ~/llama.cpp_2024_12_28/grammars/ibd_typeOnly.gbnf \
--outDir ~/results_tmp/ibd_type_all \
--sequences $(wc -l < ~/ibdType_CSVs_2025_01_08/input_1_of_3.txt) \
--n-gpu-layers 99 --ctx-size 65536 \
--IDfile ~/ibdType_CSVs_2025_01_08/ptIDs_1_of_3.txt \
--file ~/ibdType_CSVs_2025_01_08/input_1_of_3.txt \
--temp 0 -fa --promptFormat phi4 \
--systemPromptFile ~/llama.cpp_2024_12_28/system_prompts/phi4/IBD_typeOnly.txt \
--parallel 16 -sm none -mg 0


~/llama.cpp_2024_12_28/build/bin/llama-data-extraction -m ./models_gguf/gemma-2-9B-SPPO_f16.gguf \
--grammar-file ~/llama.cpp_2024_12_28/grammars/ibd_typeOnly.gbnf \
--outDir ~/results_tmp/ibd_type_all \
--sequences $(wc -l < ~/ibdType_CSVs_2025_01_08/input_2_of_3.txt) \
--n-gpu-layers 99 --ctx-size 65536 \
--IDfile ~/ibdType_CSVs_2025_01_08/ptIDs_2_of_3.txt \
--file ~/ibdType_CSVs_2025_01_08/input_2_of_3.txt \
--temp 0 -fa --promptFormat gemma2 \
--systemPromptFile ~/llama.cpp_2024_12_28/system_prompts/gemma2/IBD_typeOnly.txt \
--parallel 24 -sm none -mg 0


~/llama.cpp_2024_12_28/build/bin/llama-data-extraction -m ./models_gguf/gemma-2-9B-SPPO_f16.gguf \
--grammar-file ~/llama.cpp_2024_12_28/grammars/ibd_typeOnly.gbnf \
--outDir ~/results_tmp/ibd_type_all \
--sequences $(wc -l < ~/ibdType_CSVs_2025_01_08/input_3_of_3.txt) \
--n-gpu-layers 99 --ctx-size 65536 \
--IDfile ~/ibdType_CSVs_2025_01_08/ptIDs_3_of_3.txt \
--file ~/ibdType_CSVs_2025_01_08/input_3_of_3.txt \
--temp 0 -fa --promptFormat gemma2 \
--systemPromptFile ~/llama.cpp_2024_12_28/system_prompts/gemma2/IBD_typeOnly.txt \
--parallel 16 -sm none -mg 0

