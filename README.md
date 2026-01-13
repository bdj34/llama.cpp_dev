# llama.cpp_dev

This is a fork of the main [llama.cpp GitHub](https://github.com/ggml-org/llama.cpp) which can be found at https://github.com/ggml-org/llama.cpp.
I have added a few command-line parameters and an example called `data-extraction` (under examples/data-extraction) for the purpose of structuring electronic health record (EHR) note data using LLMs.

This is the code we used for the work in our paper in press (DOI coming soon). For exact reproduction of our prior work ("Large language models for extracting histopathologic diagnoses of colorectal cancer and dysplasia from electronic health records" [PMID: 40973184](https://pubmed.ncbi.nlm.nih.gov/40973184/) [DOI: 10.1136/bmjgast-2025-001896](https://bmjopengastro.bmj.com/content/12/1/e001896)), see the [old repo](https://github.com/bdj34/llama.cpp_data_extraction) at https://github.com/bdj34/llama.cpp_data_extraction. 

Create an issue on this repo or reach out to me at brian.d.johnson97@gmail.com or bdj001@ucsd.edu if you have questions!

To reproduce our implementation and analysis from paper(s), see the directory "reproduce_results". These are broken down into separate directories for pre-processing, inference, post-processing, and calculate-metrics. The UC-CaRE validation paper (DOI coming soon) is under the UC-CaRE sub-directory. There are separate READMEs under each of these directories to make sense of the scripts and what we did. 

**Supported/recommended models and updates:**  
This fork is up to date with the main `llama.cpp` GitHub as of **Nov 11, 2025**. Any models released after that date will likely not work because the llama.cpp codebase usually has to make modifications to accomodate new models. I will try to keep this code update every few months to accomodate newer models and advancements in inference efficiency. Hopefully this repo can also serve as a guide for people to adapt the main llama.cpp GitHub to suit their needs. If something breaks with llama.cpp updates, I have tagged previous merges (see tags) so that we can go back to older versions of the code if necessary.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)

---


## Demo: Air-gapped Server Setup

We focus on compiling this software on a remote server **without internet access**.

**Step 1: Clone, compress, and transfer**
```bash
git clone https://github.com/bdj34/llama.cpp_data_extraction
tar -czvf DESIRED_PATH/llama.cpp_data_extraction.tar.gz -C PATH_USED_FOR_GIT_CLONE/llama.cpp_data_extraction .
```

Transfer `llama.cpp_data_extraction.tar.gz` to the server.  
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
mkdir llama.cpp_data_extraction
tar -xzvf llama.cpp_data_extraction.tar.gz -C llama.cpp_data_extraction/
cd llama.cpp_data_extraction
cmake -B build --fresh
cmake --build build --config Release
```

### With GPU (CUDA)
```bash
mkdir llama.cpp_data_extraction
tar -xzvf llama.cpp_data_extraction.tar.gz -C llama.cpp_data_extraction/
cd llama.cpp_data_extraction
cmake -B build -DGGML_CUDA=ON --fresh
cmake --build build --config Release
```

---

## Compiling on Windows

Unzip and expand the .tar.gz (using 7zip), then change directory into the expanded directory.  

*(Untested by me — instructions copied from `llama.cpp`. Refer to the main repo for support.)*  
- Building for Windows (x86, x64 and arm64) with MSVC or clang as compilers:
    - Install Visual Studio 2022, e.g. via the [Community Edition](https://visualstudio.microsoft.com/vs/community/). In the installer, select at least the following options (this also automatically installs the required additional tools like CMake,...):
    - Tab Workload: Desktop-development with C++
    - Tab Components (select quickly via search): C++-_CMake_ Tools for Windows, _Git_ for Windows, C++-_Clang_ Compiler for Windows, MS-Build Support for LLVM-Toolset (clang)
    - Please remember to always use a Developer Command Prompt / PowerShell for VS2022 for git, build, test
    - For Windows on ARM (arm64, WoA) build with:
    ```bash
    cd PATH_TO_DIR/llama.cpp_data_extraction
    cmake --preset arm64-windows-llvm-release -D GGML_OPENMP=OFF
    cmake --build build-arm64-windows-llvm-release
    ```
    Building for arm64 can also be done with the MSVC compiler with the build-arm64-windows-MSVC preset, or the standard CMake build instructions. However, note that the MSVC compiler does not support inline ARM assembly code, used e.g. for the accelerated Q4_0_N_M CPU kernels.

    For building with ninja generator and clang compiler as default:  
      -set path:set LIB=C:\Program Files (x86)\Windows Kits\10\Lib\10.0.22621.0\um\x64;C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.41.  34120\lib\x64\uwp;C:\Program Files (x86)\Windows Kits\10\Lib\10.0.22621.0\ucrt\x64  
      ```bash
      cmake --preset x64-windows-llvm-release
      cmake --build build-x64-windows-llvm-release
      ```
---

## Compiling on macOS (Apple Silicon)

*(I have tested this and it should work. Let me know if there are issues.)*
```bash
cd PATH_TO_DIR/llama.cpp_data_extraction
cmake -B build
cmake --build build --config Release
```

## Compiling without cmake (linux and/or mac; deprecated by llama.cpp)
*(I have tested this and it should work. Let me know if there are issues.)*
```bash
cd PATH_TO_DIR/llama.cpp_data_extraction
make
```

---

## Example running command (if compiled with cmake)
```bash
cd PATH_TO_DIR/llama.cpp_data_extraction
mkdir -p ../testing_CRC_extraction_outDir

./build/bin/data-extraction --extractionType crc \
-m PATH_TO_GGUF/Gemma-2-9B-It-SPPO-Iter3-fp16.gguf \
--sequences 16 --parallel 4 --n-predict 300 \
--batch-size 2048 --n-gpu-layers 99 --ctx-size 2000 \
--temp 0 \
--promptStartingNumber 0 \
--patientFile ./example_data/fake_patientIDs.txt \
--grammar-file ./grammars/yesNo_grammar.gbnf \
--outDir ../testing_CRC_extraction_outDir \
--file ./example_data/pathMaybe.txt \
--promptFormat gemma2 
```

## Example running command (if compiled with make; officially deprecated)  

The only difference is that the path to the binary "data-extraction" changes  

```bash
cd PATH_TO_DIR/llama.cpp_data_extraction
mkdir -p ../testing_CRC_extraction_outDir

./data-extraction --extractionType crc \
-m PATH_TO_GGUF/Gemma-2-9B-It-SPPO-Iter3-fp16.gguf \
--sequences 16 --parallel 4 --n-predict 300 \
--batch-size 2048 --n-gpu-layers 99 --ctx-size 2000 \
--temp 0 \
--promptStartingNumber 0 \
--patientFile ./example_data/fake_patientIDs.txt \
--grammar-file ./grammars/yesNo_grammar.gbnf \
--outDir ../testing_CRC_extraction_outDir \
--file ./example_data/pathMaybe.txt \
--promptFormat gemma2 
```

## Parameter Descriptions

| Parameter | Description |
|----------|-------------|
| `--extractionType` | Type of extraction to perform; `crc` refers to colorectal cancer-specific extraction. Other options are indefinite for dysplasia (`ind`), any dysplasia (`lgd`), and high grade dysplasia and/or adenocarcinoma (`advNeo`). |
| `-m <path>` | Path to the GGUF model file to use for inference. |
| `--sequences <int>` | Number of input sequences (path reports) to process. |
| `--parallel <int>` | Number of prompts to process in parallel. |
| `--n-predict <int>` | Maximum number of tokens to generate for each prompt. Anything above 1 should be sufficient for a "yes"/"no" |
| `--batch-size <int>` | Token batch size for inference. I recommend setting to 2048 because I sometimes observed errors for other values. |
| `--n-gpu-layers <int>` | Number of model layers to offload to the GPU. Set to 99 for all if your entire model+context fits on your GPU. Set to 0 for CPU only inference. |
| `--ctx-size <int>` | Context window size in tokens. Must be less than or equal to the model’s maximum context length multiplied by value given for `--parallel`. Also, must be low enough so that the model+context fits within your GPU VRAM (or CPU RAM, if only using CPU). |
| `--temp <float>` | Temperature for sampling; 0 means deterministic output. We always used 0. |
| `--promptStartingNumber <int>` | Used for indexing or resuming prompts from a specific starting number. Helpful if you get an error somewhere in the middle and want to resume from there. |
| `--patientFile <path>` | File containing path report (or patient) identifiers. Identifier will be save with LLM answer as tab separated txt file. |
| `--grammar-file <path>` | Path to the GBNF grammar file used to constrain output format. |
| `--outDir <path>` | Directory where output files will be saved. |
| `--file <path>` | Path to the input file containing text to process. Each path report should be on a new line, with new lines within each path report escaped "\n" -> "\\n" |
| `--promptFormat <name>` | Prompt formatting to match with formatting model was trained on (Options: `gemma2`, `llama3`, `mistral` or `phi3`). |

## Description (copied from main llama.cpp page)

The main goal of `llama.cpp` is to enable LLM inference with minimal setup and state-of-the-art performance on a wide variety of hardware — locally and in the cloud.

- Plain C/C++ implementation with zero dependencies
- First-class support for Apple Silicon (ARM NEON, Accelerate, Metal)
- AVX, AVX2, AVX512, and AMX support for x86 CPUs
- Support for 1.5–8 bit quantization
- CUDA kernels for NVIDIA GPUs; HIP support for AMD; MUSA for Moore Threads GPUs
- Vulkan and SYCL backends
- Hybrid CPU+GPU inference to enable running models larger than VRAM

