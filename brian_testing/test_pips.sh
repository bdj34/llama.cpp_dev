# Med Gemma 3 27B
cd /Users/brianjohnson/VA_IBD/llama.cpp_dev_merge_public_20251111
./build/bin/llama-data-extraction \
-m ~/Downloads/models_gguf/medgemma-27b-text-it-Q6_K.gguf \
-sysf ./system_prompts/gemma/pips_strictures_tubular_colon.txt \
--no-escape --swa-full \
--sequences 16 --parallel 1 --n-predict 300 --batch-size 2048 --n-gpu-layers 99 --ctx-size 8192 \
--temp 0 --saveInput \
--grammar-file ./grammars/pips_strictures_tubular_colon.gbnf \
--IDfile /Users/brianjohnson/VA_IBD/testing_data/IBD_hx_deID/concat_patientIDs_06042024.txt \
--outDir ../llm_ibd_outDir \
--file /Users/brianjohnson/VA_IBD/testing_CRC_extraction_outDir/inputTextNoFormatting_2024-06-27_11-59-22.txt \
--promptFormat gemma2