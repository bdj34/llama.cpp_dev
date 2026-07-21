# llama.cpp_dev

This is a fork of the main [llama.cpp GitHub](https://github.com/ggml-org/llama.cpp) which can be found at https://github.com/ggml-org/llama.cpp.
I have added a few command-line parameters and an example called `data-extraction` (under examples/data-extraction) for the purpose of structuring electronic health record (EHR) note data using LLMs.

This is the code we used for the work in our paper in press (DOI coming soon). For exact reproduction of our prior work ("Large language models for extracting histopathologic diagnoses of colorectal cancer and dysplasia from electronic health records" [PMID: 40973184](https://pubmed.ncbi.nlm.nih.gov/40973184/) [DOI: 10.1136/bmjgast-2025-001896](https://bmjopengastro.bmj.com/content/12/1/e001896)), see the [old repo](https://github.com/bdj34/llama.cpp_data_extraction) at https://github.com/bdj34/llama.cpp_data_extraction. 

Create an issue on this repo or reach out to me at brian.d.johnson97@gmail.com or bdj001@ucsd.edu if you have questions!

To reproduce our implementation and analysis from paper(s), see the directory "reproduce_results". These are broken down further into task-specific directories. The UC-CaRE validation paper (DOI coming soon) is documented under the UC-CaRE sub-directory. There are separate READMEs under each of these directories to make sense of the scripts and what we did. 

**Supported/recommended models and updates:**  
This fork is up to date with the main `llama.cpp` GitHub as of **Nov 11, 2025**. Any models released after that date will likely not work because the main [llama.cpp GitHub](https://github.com/ggml-org/llama.cpp) usually has to make modifications to accomodate new models. I will try to keep this code updated every few months to accomodate newer models and advancements in inference efficiency. Hopefully, this fork can also serve as a guide for people to adapt the main llama.cpp GitHub to suit their needs. If something breaks with updates, I have tagged previous merges (see tags) so that we can go back to older versions of the code if necessary.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)

---


## Demo: Air-gapped Server Setup

We focus on compiling this software on a remote server **without internet access**.

**Step 1: Clone, compress, and transfer**
```bash
git clone https://github.com/bdj34/llama.cpp_dev
tar -czvf DESIRED_PATH/llama.cpp_dev.tar.gz -C PATH_USED_FOR_GIT_CLONE/llama.cpp_dev .
```

Transfer `llama.cpp_dev.tar.gz` to the server.  
*(Example: at the VA, I transfer it via MS Teams to my VA computer, then upload it using the VINCI upload tool.)*

**Step 2: Download model and transfer**  

Visit [HuggingFace](https://huggingface.co/briandj97/models_used/tree/main) to download one of the GGUF models used in our work (or use your own).
As in step 1, transfer the gguf file to the remote server.  
*(Example: at the VA, I split the gguf, transfer it via MS Teams to my VA computer, then email VINCI asking them to upload a large file.)*

**Step 3: Unzip and compile**  

Platform dependent: see below.

---

## Unzipping and compiling on Linux

### No GPU
```bash
mkdir llama.cpp_dev
tar -xzvf llama.cpp_dev.tar.gz -C llama.cpp_dev/
cd llama.cpp_dev
cmake -B build --fresh
cmake --build build --config Release
```

### With GPU (CUDA)
```bash
mkdir llama.cpp_dev
tar -xzvf llama.cpp_dev.tar.gz -C llama.cpp_dev/
cd llama.cpp_dev
cmake -B build -DGGML_CUDA=ON --fresh
cmake --build build --config Release
```

---

## Compiling on Windows

Unzip and expand the .tar.gz (using 7zip), then change directory into the expanded directory.  
Use windows build directions from main llama.cpp repo (https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md).

## Compiling on macOS (Apple Silicon)

*(I have tested this and it should work. Let me know if there are issues.)*
```bash
cd PATH_TO_DIR/llama.cpp_dev
cmake -B build
cmake --build build --config Release
```

## Compiling without cmake (linux and/or mac; deprecated by llama.cpp)
*(I have tested this on older versions, but try to use cmake if possible. If this isn't working, try using older tagged versions of the code.)*
```bash
cd PATH_TO_DIR/llama.cpp_dev
make
```

---

## Example running command (if compiled with cmake)
```bash 
cd ~/llama.cpp_dev
mkdir -p ~/completeness/results

./build/bin/llama-data-extraction \
-m ~/models_gguf/medGemma-27B.gguf \
-sysf ./system_prompts/gemma2/completenessOfResection.txt \
--no-escape --swa-full \
--sequences $(wc -l < ~/completeness/inputs/inputs.txt) \
--parallel 4 --n-predict 30 --batch-size 2048 --n-gpu-layers 0 --ctx-size 16384 \
--temp 0 \
--IDfile ~/completeness/inputs/sid_and_sample.txt \
--grammar-file ./grammars/completenessOfResection.gbnf \
--outDir ~/completeness/results \
--file ~/completeness/inputs/inputs.txt \
--promptFormat gemma2
```

## Example running command (if compiled with make; officially deprecated)  

The only difference is that the path to the binary "data-extraction" changes  

```bash
cd ~/llama.cpp_dev
mkdir -p ~/completeness/results

./llama-data-extraction \
-m ~/models_gguf/medGemma-27B.gguf \
-sysf ./system_prompts/gemma2/completenessOfResection.txt \
--no-escape --swa-full \
--sequences $(wc -l < ~/completeness/inputs/inputs.txt) \
--parallel 4 --n-predict 30 --batch-size 2048 --n-gpu-layers 0 --ctx-size 16384 \
--temp 0 \
--IDfile ~/completeness/inputs/sid_and_sample.txt \
--grammar-file ./grammars/completenessOfResection.gbnf \
--outDir ~/completeness/results \
--file ~/completeness/inputs/inputs.txt \
--promptFormat gemma2
```

## Parameter Descriptions

| Parameter | Description |
|----------|-------------|
| `-m <path>` | Path to the GGUF model file to use for inference. |
| `--sequences <int>` | Total number of input sequences (e.g., pathology reports) to process. |
| `--parallel <int>` | Number of prompts to process in parallel. |
| `--n-predict <int>` | Maximum number of tokens to generate for each prompt. Anything above 1 should be sufficient for a "yes"/"no" |
| `--batch-size <int>` | Token batch size for inference. I recommend setting to 2048 because I sometimes observed errors for other values. |
| `--n-gpu-layers <int>` | Number of model layers to offload to the GPU. Set to 99 for all if your entire model+context fits on your GPU. Set to 0 for CPU only inference. If you have a small GPU and want to do partial offloading, you can set this accordingly (see main [llama.cpp GitHub](https://github.com/ggml-org/llama.cpp) for more info). |
| `--ctx-size <int>` | Context size in tokens. Must be less than or equal to the model’s maximum context length multiplied by value given for `--parallel`. Also, must be low enough so that the model+context fits within your GPU VRAM (or CPU+GPU RAM if doing partial offloading or CPU RAM if only using CPU). |
| `--temp <float>` | Temperature for sampling; 0 means deterministic output. We always used 0. |
| `--sysf <path>` | Path to system prompt file. This must be a .txt file. Examples we used are found in `system_prompts` directory. |
| `--IDFile <path>` | Path to txt file containing identifiers for each input (one line per identifier). This can be patient IDs, note IDs, or any other ID that is useful. Identifier will be saved with LLM answer as tab separated txt file. |
| `--grammar-file <path>` | Path to the GBNF grammar file used to constrain output format. |
| `--outDir <path>` | Directory where output files will be saved. |
| `--file <path>` | Path to the input file containing text to process. Each input should be on a new line, with new lines within each input escaped "\n" -> "\\\n". The current logic converts the "\\\n" to "\n" before inference. |
| `--promptFormat <name>` | Prompt formatting to match with formatting model was trained on (Options: `gemma2`, `llama3`, `mistral` or `phi3`). |
| `--no-escape` | Whether to process escape sequences. Must be included or the inputs will not be processed correctly. 
| `--swa-full` | SWA = Sliding window attention. This may not be necessary but I've had errors when leaving it out that resolve when including it. See [main repo](https://github.com/ggml-org/llama.cpp) for details. 




# To stay up-to-date with the GGML public repo:
## Merge from ggerganov/ repo
git checkout master
git pull origin master --no-rebase
# Manually resolve merges (or do in Merge editor in VS code), then do:
git add .
git commit

