#!/bin/bash

cd ~/llama.cpp_2025_06_10

./build/bin/llama-data-extraction \
-m ~/media/disk/_cygdrive_P_ORD_Curtius_202210036D_nlp_v2/models_gguf/medgemma-27b-text-it-Q4KM.gguf \
-sysf ./system_prompts/gemma2/completenessOfResection.txt \
--no-escape \
--sequences $(wc -l < ../completeness/inputs/input.txt) \
--parallel 1 --n-predict 30 --batch-size 2048 --n-gpu-layers 0 --ctx-size 4096 \
--temp 0 \
--IDfile ../completeness/inputs/sid_and_sample.txt \
--grammar-file ./grammars/completenessOfResection.gbnf \
--outDir ../completeness/results \
--file ../completeness/inputs/input.txt \
--promptFormat gemma2
