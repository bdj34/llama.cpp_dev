// Based on examples/parallel, with modifications to allow accurate and 
// efficient data structuring.

#include "arg.h"
#include "common.h"
#include "sampling.h"
#include "log.h"
#include "llama.h"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>
#include <ctime>
#include <algorithm>
#include <iostream>
#include <fstream>

std::string generatePreAnswer(const std::string& promptFormat);
std::string escapeNewLines(const std::string& input);
std::string convertEscapedNewlines(const std::string& input);

// trim whitespace from the beginning and end of a string
static std::string trim(const std::string & str) {
    size_t start = 0;
    size_t end = str.size();

    while (start < end && isspace(str[start])) {
        start += 1;
    }

    while (end > start && isspace(str[end - 1])) {
        end -= 1;
    }

    return str.substr(start, end - start);
}

std::string convertEscapedNewlines(const std::string& input) {
    std::string output = input;
    size_t pos = 0;
    
    // Find and replace all occurrences of "\\n" with "\n"
    while ((pos = output.find("\\n", pos)) != std::string::npos) {
        output.replace(pos, 2, "\n");
        pos += 1; // Move past the newly inserted '\n' to avoid infinite loop
    }
    
    return output;
}


std::vector<std::string> k_prompts;

std::string escapeNewLines(const std::string& input) {

    std::string output;

    for (char ch : input) {
        switch (ch) {
            case '\n':
                output += "\\n";   // Escape newlines
                break;
            default:
                output += ch;
        }
    }
    return output;
}

std::string k_system;

struct client {
    ~client() {
        if (smpl) {
            common_sampler_free(smpl);
        }
    }

    int32_t id = 0;

    llama_seq_id seq_id = -1;

    llama_token sampled;

    int64_t t_start_prompt;
    int64_t t_start_gen;

    int32_t n_past    = 0;
    int32_t n_prompt  = 0;
    int32_t n_decoded = 0;
    int32_t i_batch   = -1;

    std::string input;
    std::string prompt;
    std::string response;
    std::string inputID;

    struct common_sampler * smpl = nullptr;
};

std::string generatePreAnswer(const std::string& promptFormat) {

    if (promptFormat == "mistral") {
        return "[/INST]";
    } else if (promptFormat == "llama3") {
        return "<|eot_id|>\n<|start_header_id|>assistant<|end_header_id|>\n\n";
    } else if (promptFormat == "phi4") {
        return "<|im_end|>\n<|im_start|>assistant<|im_sep|>\n";
    } else if (promptFormat == "gemma2") {
        return "<end_of_turn>\n<start_of_turn>model\n";
    } else if (promptFormat == "qwen") {
        return "<|im_end|>\n<|im_start|>assistant\n";
    } else if (promptFormat == "R1") {
        return "<｜Assistant｜>\n";
    } else {
        throw std::runtime_error("Error: prompt format not recognized. Recognized options are: gemma2, phi4, llama3, mistral, qwen, R1.");
    }
}

static void print_date_time() {
    std::time_t current_time = std::time(nullptr);
    std::tm* local_time = std::localtime(&current_time);
    char buffer[80];
    strftime(buffer, sizeof(buffer), "%Y-%m-%d %H:%M:%S", local_time);

    LOG_INF("\n");
    LOG_INF("\033[35mrun parameters as of %s\033[0m\n", buffer);
    LOG_INF("\n");
}

// Define a split string function to ...
static std::vector<std::string> split_string(const std::string& input, char delimiter) {
    std::vector<std::string> tokens;
    std::istringstream stream(input);
    std::string token;
    while (std::getline(stream, token, delimiter)) {
        tokens.push_back(token);
    }
    return tokens;
}

int main(int argc, char ** argv) {
    srand(1234);

    common_params params;

    if (!common_params_parse(argc, argv, params, LLAMA_EXAMPLE_PARALLEL)) {
        return 1;
    }

    common_init();

    // Get current time
    std::time_t now = std::time(nullptr);
    std::tm* now_tm = std::localtime(&now);
    // Buffer to hold the date-time format
    char dateTimeBuffer[60];  // Ensure the buffer is large enough for the format
    // Format the date and time with strftime
    strftime(dateTimeBuffer, sizeof(dateTimeBuffer), "%Y-%m-%d_%H-%M-%S", now_tm);
    // Convert to string for use in filenames or other outputs
    std::string dateTimeOutFile = dateTimeBuffer;

    // Set file names
    std::string dirPath = params.outDir;
    std::string inputFile = dirPath + "/inputTextNoFormatting_" + dateTimeOutFile + ".txt";
    std::string metadataFile = dirPath + "/metadata_" + dateTimeOutFile + ".txt";
    std::string outputFile = dirPath + "/output_" + dateTimeOutFile + ".txt";
    std::string log_file = dirPath + "/log_" + dateTimeOutFile + ".txt";
    struct common_log *log = common_log_main();
    common_log_set_file(log, log_file.c_str());

    // number of simultaneous "clients" to simulate
    const int32_t n_clients = params.n_parallel;

    // dedicate one sequence to the system prompt
    params.n_parallel += 1;

    // requests to simulate
    const int32_t n_seq = params.n_sequences;

    // insert new requests as soon as the previous one is done
    const bool cont_batching = params.cont_batching;

    // is the system prompt shared in the cache
    const bool is_sp_shared = true;

    // init llama.cpp
    llama_backend_init();
    llama_numa_init(params.numa);

    // load the target model
    common_init_result llama_init = common_init_from_params(params);

    llama_model * model = llama_init.model.get();
    llama_context * ctx = llama_init.context.get();

    auto * mem = llama_get_memory(ctx);

    const llama_vocab * vocab = llama_model_get_vocab(model);

    std::vector<std::string> allPrompts;
    std::vector<std::string> allIDs;
    std::ofstream outFile1(inputFile.c_str());

    // load the prompts from an external file if there are any
    if (params.prompt.empty()) {
        throw std::runtime_error("Error: No prompts given");
    } else {
        // Output each line of the input params.prompts vector and copy to k_prompts
        int index = 0;
        LOG_INF("\033[32mNow printing the external prompt file %s\033[0m\n\n", params.prompt_file.c_str());

        // Create and open a text file (if input is to be saved)
        if(params.saveInput){

            // Check if the file was opened successfully
            if (!outFile1) {
                std::cerr << "Failed to open the input prompt out file." << std::endl;
                return 1; // Return with error code
            }
        }else{
            outFile1 << "Input prompts not written to outfile because saveInput = false" << std::endl;
        }

        allPrompts = split_string(params.prompt, '\n');
        allIDs = split_string(params.IDs, '\n');

        // Print the prompts and write to outfile (only those equal to or after starting index)
        std::string tmpPrompt;
        for (const auto& prompt : allPrompts) {
            k_prompts.resize(index + 1);
            tmpPrompt = prompt + generatePreAnswer(params.promptFormat);
            k_prompts[index] = tmpPrompt;

            // Write each prompt to the out file
            if(params.saveInput){
                outFile1 << prompt << std::endl; // Adding newline for separation in file
            }
            index++;
            //LOG_INF("%3d prompt: %s\n", index, prompt.c_str());
        }

        // Close the file
        if(params.saveInput){
            outFile1.close();
        }
    }

    LOG_INF("\n\n");

    const int n_ctx = llama_n_ctx(ctx);

    // Get system prompt from file/params
    k_system = convertEscapedNewlines(params.system_prompt);

    // Write format to the metadataFile
    std::string fullPrompt_example = convertEscapedNewlines(k_system) + convertEscapedNewlines(k_prompts[0]);
    std::vector<llama_token> tokens_format;
    // Bool in third arg represents BOS token, which we DO want here.
    tokens_format = ::common_tokenize(ctx, fullPrompt_example, true);
    // Create and open a text file to save the full prompt (system + input)
    std::ofstream outFile2(metadataFile.c_str());

    // Check if the file was opened successfully
    if (!outFile2) {
        std::cerr << "Failed to open the metadata out file." << std::endl;
        return 1; // Return with error code
    }

    // Write each prompt to the out file
    outFile2 << "Start date-time: " << dateTimeOutFile << std::endl;
    outFile2 << "Output file format (tab-separated): {Model answer, with newlines escaped}\t{Patient ID or SurgPathID}" << std::endl << std::endl;   
    outFile2 << "Model path: " << params.model.path << std::endl << std::endl;
    outFile2 << "Input file path: " << params.prompt_file << std::endl;
    outFile2 << "Patient ID file path (if applicable): " << params.IDfile << std::endl;
    outFile2 << "Reading until line" << n_seq << std::endl << std::endl;
    outFile2 << "Full prompt format (no escaping):" << std::endl; 
    outFile2 << fullPrompt_example << std::endl << std::endl << std::endl << "Prompt format tokenized (including BOS token):" << std::endl; // Adding newline for separation in file

    // Iterate through the vector and write each element to the file
    for (size_t i = 0; i < tokens_format.size(); ++i) {
        outFile2 << tokens_format[i] << "\t";
    }
    outFile2 << std::endl << std::endl;

    std::vector<client> clients(n_clients);
    for (size_t i = 0; i < clients.size(); ++i) {
        auto & client = clients[i];
        client.id = i;
        client.smpl = common_sampler_init(model, params.sampling);
    }

    // Initialize system prompt token vec
    std::vector<llama_token> tokens_system;
    // Print the string and tokenize
    printf("System prompt: %s\n", k_system.c_str());
    tokens_system = common_tokenize(ctx, k_system, true);
    const int32_t n_tokens_system = tokens_system.size();

    llama_seq_id g_seq_id = 0;

    // the max batch size is as large as the context to handle cases where we get very long input prompt from multiple
    // users. regardless of the size, the main loop will chunk the batch into a maximum of params.n_batch tokens at a time
    llama_batch batch = llama_batch_init(n_ctx, 0, 1);

    int32_t n_total_prompt = 0;
    int32_t n_total_gen    = 0;
    int32_t n_cache_miss   = 0;

    const auto t_main_start = ggml_time_us();

    LOG_INF("%s: Simulating parallel requests from clients:\n", __func__);
    LOG_INF("%s: n_parallel = %d, n_sequences = %d, cont_batching = %d, system tokens = %d\n", __func__, n_clients, n_seq, cont_batching, n_tokens_system);
    LOG_INF("\n");

    if (is_sp_shared) {
        LOG_INF("%s: Evaluating the system prompt ...\n", __func__);

        for (int32_t i = 0; i < n_tokens_system; ++i) {
            common_batch_add(batch, tokens_system[i], i, { 0 }, false);
        }

        if (llama_decode(ctx, batch) != 0) {
            LOG_ERR("%s: llama_decode() failed\n", __func__);
            return 1;
        }

        // assign the system KV cache to all parallel sequences
        for (int32_t i = 1; i <= n_clients; ++i) {
            llama_memory_seq_cp(mem, 0, i, -1, -1);
        }

        LOG_INF("\n");
    }

    LOG_INF("Processing requests ...\n\n");

    // Open output file to write to
    std::ofstream outFile3(outputFile.c_str());
    // Check if the file was opened successfully
    if (!outFile3) {
        std::cerr << "Failed to open the output out file." << std::endl;
        return 1; // Return with error code
    }

    size_t promptNumber = 0;

    while (true) {
        common_batch_clear(batch);

        // decode any currently ongoing sequences
        for (auto & client : clients) {
            if (client.seq_id == -1) {
                continue;
            }

            client.i_batch = batch.n_tokens;

            common_batch_add(batch, client.sampled, client.n_past++, { client.id + 1 }, true);

            client.n_decoded += 1;
        }

        if (batch.n_tokens == 0) {
            // all sequences have ended - clear the entire KV cache
            for (int i = 1; i <= n_clients; ++i) {
                llama_memory_seq_rm(mem, i, -1, -1);
                // but keep the system prompt
                llama_memory_seq_cp(mem, 0, i, -1, -1);
            }

            LOG_INF("%s: clearing the KV cache\n", __func__);
        }

        // insert new sequences for decoding
        if (cont_batching || batch.n_tokens == 0) {
            for (auto & client : clients) {
                if (client.seq_id == -1 && g_seq_id < n_seq) {
                    client.seq_id = g_seq_id;

                    client.t_start_prompt = ggml_time_us();
                    client.t_start_gen    = 0;

                    client.input    = convertEscapedNewlines(k_prompts[promptNumber]);
                    if(!params.IDfile.empty()){
                        client.inputID = allIDs[promptNumber];
                    }

                    promptNumber++;
                    client.prompt   = client.input;
                    client.response = "";

                    // construct the prompt:
                    // [system prompt] + [junk] + [user prompt]
                    client.n_past = 0;
                    client.prompt = client.input;
                    if (is_sp_shared) {
                        client.n_past = n_tokens_system;
                    } else {
                        client.prompt += k_system;
                    }

                    common_sampler_reset(client.smpl);

                    // do not prepend BOS because we have a system prompt!
                    std::vector<llama_token> tokens_prompt;
                    tokens_prompt = common_tokenize(ctx, client.prompt, false);

                    for (size_t i = 0; i < tokens_prompt.size(); ++i) {
                        common_batch_add(batch, tokens_prompt[i], client.n_past++, { client.id + 1 }, false);
                    }

                    // extract the logits only for the last token
                    if (batch.n_tokens > 0) {
                        batch.logits[batch.n_tokens - 1] = true;
                    }

                    client.n_prompt  = tokens_prompt.size();
                    client.n_decoded = 0;
                    client.i_batch   = batch.n_tokens - 1;

                    if(params.IDfile.empty()){
                        LOG_INF("\n\n\033[0mClient %3d, seq %4d, started decoding ...\033[0m\n", client.id, client.seq_id);
                    }else{
                        LOG_INF("\n\n\033[0mClient %3d, Patient %s, seq %4d, started decoding ...\033[0m\n", client.id, client.inputID.c_str(), client.seq_id);
                    }

                    g_seq_id += 1;

                    // insert new requests one-by-one
                    //if (cont_batching) {
                    //    break;
                    //}
                }
            }
        }

        if (batch.n_tokens == 0) {
            break;
        }

        // process in chunks of params.n_batch
        int32_t n_batch = params.n_batch;

        int32_t i_next = 0;

        for (int32_t i = 0; i < batch.n_tokens; i = i_next) {
            // experiment: process in powers of 2
            //if (i + n_batch > (int32_t) batch.n_tokens && n_batch > 32) {
            //    n_batch /= 2;
            //    i -= n_batch;
            //    continue;
            //}

            const int32_t n_tokens = std::min(n_batch, batch.n_tokens - i);

            llama_batch batch_view = {
                n_tokens,
                batch.token    + i,
                nullptr,
                batch.pos      + i,
                batch.n_seq_id + i,
                batch.seq_id   + i,
                batch.logits   + i,
            };

            const int ret = llama_decode(ctx, batch_view);
            if (ret != 0) {
                if (n_batch == 1 || ret < 0) {
                    // if you get here, it means the KV cache is full - try increasing it via the context size
                    LOG_ERR("%s : failed to decode the batch, n_batch = %d, ret = %d\n", __func__, n_batch, ret);
                    return 1;
                }

                LOG_WRN("%s : failed to decode the batch, retrying with n_batch = %d\n", __func__, n_batch / 2);

                n_cache_miss += 1;

                // retry with half the batch size to try to find a free slot in the KV cache
                n_batch /= 2;

                continue;
            }

            LOG_DBG("%s : decoded batch of %d tokens\n", __func__, n_tokens);

            // move the head of the batch forward with the number of tokens we just processed
            i_next = i + n_tokens;

            // on successful decode, restore the original batch size
            n_batch = params.n_batch;

            for (auto & client : clients) {
                if (client.i_batch < (int) i || client.i_batch >= (int) (i + n_tokens)) {
                    continue;
                }

                //printf("client %d, seq %d, token %d, pos %d, batch %d\n",
                //        client.id, client.seq_id, client.sampled, client.n_decoded, client.i_batch);

                const llama_token id = common_sampler_sample(client.smpl, ctx, client.i_batch - i);

                common_sampler_accept(client.smpl, id, true);

                if (client.n_decoded == 1) {
                    // start measuring generation time after the first token to make sure all concurrent clients
                    // have their prompt already processed
                    client.t_start_gen = ggml_time_us();
                }

                const std::string token_str = common_token_to_piece(ctx, id);

                client.response += token_str;
                client.sampled = id;

                // Determine when to stop generating
                if (client.n_decoded > 0 &&
                    (llama_vocab_is_eog(vocab, id) ||
                         (params.n_predict > 0 && client.n_decoded >= params.n_predict))) {


                    // Copy the client response and the ptID to the output file
                    if(!client.inputID.empty()){
                        outFile3 << escapeNewLines(client.response);
                        outFile3 << "\t" << client.inputID;
                    }else{
                        std::cerr << "No ID given to identify each input!" << std::endl;
                        return 1;
                    }
                    outFile3 << std::endl;

                    // delete only the generated part of the sequence, i.e. keep the system prompt in the cache
                    llama_memory_seq_rm(mem,    client.id + 1, -1, -1);
                    llama_memory_seq_cp(mem, 0, client.id + 1, -1, -1);

                    const auto t_main_end = ggml_time_us();

                    LOG_INF("\033[0m \nInput:\n\033[96m%s\033[91m%s\033[0m\n\033[92mJust completed: Patient: %s, sequence %3d of %3d, prompt: %4d tokens, response: %4d tokens, time: %5.2f seconds, speed %5.2f t/s",
                            //escapeNewLines(client.input).c_str(),
                            client.input.c_str(),
                            client.response.c_str(),
                            client.inputID.c_str(), client.seq_id, n_seq, client.n_prompt, client.n_decoded,
                            (t_main_end - client.t_start_prompt) / 1e6,
                            (double) (client.n_prompt + client.n_decoded) / (t_main_end - client.t_start_prompt) * 1e6);
                            // n_cache_miss,
                            //k_system.c_str(),
                            //::trim(prompts[promptNumber]).c_str());
                    
                    LOG_INF("\nJust completed ID: %s",
                        client.inputID.c_str());

                    n_total_prompt += client.n_prompt;
                    n_total_gen    += client.n_decoded;

                    client.seq_id = -1;
                }

                client.i_batch = -1;
            }
        }
    }

    // Close the file
    outFile3.close();

    // Reopen the metadata file in append mode
    std::ofstream metaFile(metadataFile, std::ios::app);  // Append mode

    // Check if the file was opened successfully
    if (!metaFile) {
        std::cerr << "Failed to open the metadata out file." << std::endl;
        return 1; // Return with error code
    }

    const auto t_main_end = ggml_time_us();

    metaFile << "Total runtime (seconds): " << (t_main_end - t_main_start)/(1e6) << std::endl;

    metaFile.close();

    print_date_time();

    LOG_INF("%s: n_parallel = %d, n_sequences = %d, cont_batching = %d, system tokens = %d\n", __func__, n_clients, n_seq, cont_batching, n_tokens_system);
    if (params.prompt_file.empty()) {
        params.prompt_file = "used built-in defaults";
    }
    LOG_INF("External prompt file: \033[32m%s\033[0m\n", params.prompt_file.c_str());
    LOG_INF("System prompt file: \033[32m%s\033[0m\n", params.systemPromptFile.c_str());
    LOG_INF("Model and path used:  \033[32m%s\033[0m\n\n", params.model.path.c_str());

    LOG_INF("Total prompt tokens: %6d, speed: %5.2f t/s\n", n_total_prompt, (double) (n_total_prompt              ) / (t_main_end - t_main_start) * 1e6);
    LOG_INF("Total gen tokens:    %6d, speed: %5.2f t/s\n", n_total_gen,    (double) (n_total_gen                 ) / (t_main_end - t_main_start) * 1e6);
    LOG_INF("Total speed (AVG):   %6s  speed: %5.2f t/s\n", "",             (double) (n_total_prompt + n_total_gen) / (t_main_end - t_main_start) * 1e6);
    LOG_INF("Cache misses:        %6d\n", n_cache_miss);

    LOG_INF("\n");

    // TODO: print sampling/grammar timings for all clients
    llama_perf_context_print(ctx);

    llama_batch_free(batch);

    llama_backend_free();

    LOG("\n\n");

    return 0;
}
