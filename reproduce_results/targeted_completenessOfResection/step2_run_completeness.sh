#!/bin/bash

cd ~/llama.cpp_20251112

./build/bin/llama-data-extraction \
-m ~/medGemma_27B_it_Q4KM.gguf \
-sysf ./system_prompts/gemma/completenessOfResection.txt \
--no-escape \
--sequences $(wc -l < ../completeness/inputs/inputs.txt) \
--parallel 1 --n-predict 30 --batch-size 2048 --n-gpu-layers 42 --ctx-size 32768 \
--temp 0 --threads 47 \
--IDfile ../completeness/inputs/PathID_and_sample.txt \
--grammar-file ./grammars/completenessOfResection.gbnf \
--outDir ../completeness/results \
--file ../completeness/inputs/inputs.txt \
--promptFormat gemma2
