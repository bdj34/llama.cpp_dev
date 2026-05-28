# Med Gemma 3 27B
cd /Users/brianjohnson/VA_IBD/llama.cpp_dev_merge_public
./build/bin/llama-data-extraction \
-m ~/Downloads/models_gguf/medgemma-27b-text-it-Q4_K_M.gguf \
-sysf ./system_prompts/gemma/histologic_colitis.txt \
--no-escape --swa-full \
--sequences 5 --parallel 3 --n-predict 300 --batch-size 2048 --n-gpu-layers 99 --ctx-size 8192 \
--temp 0 --saveInput \
--grammar-file ./grammars/histologic_colitis.gbnf \
--IDfile /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/IDs.txt \
--outDir ../testing_data/histo_colitis/output \
--file /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/inputs.txt \
--promptFormat gemma2

# Gemma 4
cd /Users/brianjohnson/VA_IBD/llama.cpp_dev_merge_public
./build/bin/llama-data-extraction \
-m ~/Downloads/models_gguf/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf \
-sysf ./system_prompts/gemma/histologic_colitis.txt \
--no-escape \
--sequences 5 --parallel 3 --n-predict 300 --batch-size 2048 --n-gpu-layers 99 --ctx-size 8192 \
--temp 0 --saveInput \
--grammar-file ./grammars/histologic_colitis.gbnf \
--IDfile /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/IDs.txt \
--outDir ../testing_data/histo_colitis/output \
--file /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/inputs.txt \
--promptFormat gemma2