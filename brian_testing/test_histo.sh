# Med Gemma 3 27B
cd /Users/brianjohnson/VA_IBD/llama.cpp_dev_merge_public
./build/bin/llama-data-extraction \
-m ~/Downloads/models_gguf/medgemma-27b-text-it-Q4_K_M.gguf \
-sysf ./system_prompts/gemma/histologic_colitis.txt \
--no-escape \
--sequences 5 --parallel 1 --n-predict 300 --batch-size 2048 --n-gpu-layers 99 --ctx-size 8192 \
--temp 0 --saveInput \
--grammar-file ./grammars/histologic_colitis.gbnf \
--IDfile /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/IDs.txt \
--outDir ../testing_data/histo_colitis/output \
--file /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/inputs.txt \
--promptFormat gemma2

# Gemma 4
cd /Users/brianjohnson/VA_IBD/llama.cpp_dev
./build/bin/llama-data-extraction \
-m ~/Downloads/models_gguf/gemma-4-26B-A4B-it-UD-Q6_K.gguf \
-sysf ./system_prompts/gemma/histologic_colitis.txt \
--no-escape \
--sequences 5 --parallel 5 \
--temp 0 --saveInput \
--IDfile /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/IDs.txt \
--outDir ../testing_data/histo_colitis/output \
--file /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/inputs.txt \
--promptFormat gemma4

# Gemma 3
cd /Users/brianjohnson/VA_IBD/llama.cpp_dev_merge_public
./build/bin/llama-data-extraction \
-m ~/Downloads/models_gguf/google_gemma-3-27b-it-Q6_K_L.gguf \
-sysf ./system_prompts/gemma/histologic_colitis.txt \
--no-escape \
--sequences 5 --parallel 5 \
--temp 0 --saveInput \
--IDfile /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/IDs.txt \
--outDir ../testing_data/histo_colitis/output \
--file /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/inputs.txt \
--promptFormat gemma2

# Qwen
./build/bin/llama-data-extraction \
-m ~/Downloads/models_gguf/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf \
-sysf ./system_prompts/qwen/histologic_colitis.txt \
--no-escape \
--sequences 5 --parallel 5 \
--temp 0 --saveInput \
--grammar-file ./grammars/histologic_colitis.gbnf \
--IDfile /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/IDs.txt \
--outDir ../testing_data/histo_colitis/output \
--file /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/inputs.txt \
--promptFormat qwen

# Mistral

./build/bin/llama-data-extraction \
-m ~/Downloads/models_gguf/mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf \
-sysf ./system_prompts/mistral/histologic_colitis.txt \
--no-escape \
--sequences 5 --parallel 5 \
--temp 0 --saveInput \
--grammar-file ./grammars/histologic_colitis.gbnf \
--IDfile /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/IDs.txt \
--outDir ../testing_data/histo_colitis/output \
--file /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/inputs.txt \
--promptFormat mistral

--grammar-file ./grammars/histologic_colitis.gbnf \
\ #--n-predict 300 --batch-size 2048 --n-gpu-layers 99 --ctx-size 8192 \