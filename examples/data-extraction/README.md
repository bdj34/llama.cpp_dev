# llama.cpp/example/data-extraction

Simplified processing of clinical notes for extracting structured data

## Example

Structure data on IBD type from 128 patients (`-ns 128`), processing 2 patients at a time (`-np 8`). The system prompt is always shared, saving compute.

```bash
./build/bin/llama-data-extraction --systemPromptFile ./system_prompts/gemma2/IBD_typeOnly.txt \
-m ./model.gguf \
--sequences 128 --parallel 2 --n-predict 300 --batch-size 2048 --n-gpu-layers 99 --ctx-size 8192 \
--temp 0 --saveInput \
--IDfile ./ptIDs.txt \
--grammar-file ./grammars/ibd_typeOnly.gbnf \
--outDir ../llm_ibd_outDir \
--file ./notes.txt \
--promptFormat gemma2 
```

