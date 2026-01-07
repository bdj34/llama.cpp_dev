# Med Gemma 3 27B
cd /Users/brianjohnson/VA_IBD/llama.cpp_dev_merge_public_20251111
./build/bin/llama-data-extraction \
-m ~/Downloads/models_gguf/medgemma-27b-text-it-Q6_K.gguf \
-sysf ./system_prompts/gemma/histologic_colitis.txt\
--no-escape --swa-full \
--sequences 5 --parallel 1 --n-predict 300 --batch-size 2048 --n-gpu-layers 99 --ctx-size 8192 \
--temp 0 --saveInput \
--IDfile /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/IDs.txt \
--outDir ../testing_data/histo_colitis/output \
--file /Users/brianjohnson/VA_IBD/testing_data/histo_colitis/inputs.txt \
--promptFormat gemma2
