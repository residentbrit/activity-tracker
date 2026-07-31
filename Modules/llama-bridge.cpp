// Thin C wrapper around llama.cpp's embedding pathway.
// Compiled as part of the static library, linked into the Swift binary.

#include "llama-bridge.h"
#include "llama.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static char g_error[1024] = {0};

struct llama_embed_ctx {
    struct llama_model *model;
    struct llama_context *ctx;
    int n_embd;
};

const char* llama_embed_error(void) {
    return g_error;
}

llama_embed_ctx* llama_embed_load(const char *model_path) {
    g_error[0] = 0;

    // Initialize llama backend (Metal/Accelerate on macOS)
    llama_backend_init();

    // Load model
    struct llama_model_params model_params = llama_model_default_params();
    struct llama_model *model = llama_model_load_from_file(model_path, model_params);
    if (!model) {
        snprintf(g_error, sizeof(g_error), "failed to load model: %s", model_path);
        return NULL;
    }

    // Create context — we only need embedding, not generation
    struct llama_context_params ctx_params = llama_context_default_params();
    ctx_params.embeddings = true;
    ctx_params.pooling_type = LLAMA_POOLING_TYPE_MEAN;

    struct llama_context *ctx = llama_init_from_model(model, ctx_params);
    if (!ctx) {
        snprintf(g_error, sizeof(g_error), "failed to create context");
        llama_model_free(model);
        return NULL;
    }

    llama_embed_ctx *result = calloc(1, sizeof(llama_embed_ctx));
    result->model = model;
    result->ctx = ctx;
    result->n_embd = llama_n_embd(model);

    return result;
}

void llama_embed_free(llama_embed_ctx *ctx) {
    if (!ctx) return;
    llama_free(ctx->ctx);
    llama_model_free(ctx->model);
    llama_backend_free();
    free(ctx);
}

int llama_embed_dim(llama_embed_ctx *ctx) {
    return ctx ? ctx->n_embd : 0;
}

float* llama_embed_run(llama_embed_ctx *ctx, const char *text, int *dim) {
    g_error[0] = 0;
    if (!ctx || !text) {
        snprintf(g_error, sizeof(g_error), "null context or text");
        return NULL;
    }

    // Tokenize
    int n_tokens = llama_n_ctx(ctx->ctx);
    llama_token *tokens = calloc(n_tokens, sizeof(llama_token));
    int token_count = llama_tokenize(ctx->model, text, (int)strlen(text), tokens, n_tokens, true, false);
    if (token_count < 0) {
        snprintf(g_error, sizeof(g_error), "tokenization failed");
        free(tokens);
        return NULL;
    }

    // Run forward pass (encode)
    // We need a batch large enough for all tokens
    struct llama_batch batch = llama_batch_init(token_count, 0, 1);
    for (int i = 0; i < token_count; i++) {
        llama_batch_add(batch, tokens[i], i, (int[]){0}, false);
    }

    if (llama_encode(ctx->ctx, batch) != 0) {
        snprintf(g_error, sizeof(g_error), "encode failed");
        llama_batch_free(batch);
        free(tokens);
        return NULL;
    }

    // Extract pooled embedding (mean pooling, single sequence)
    float *embd = llama_get_embeddings(ctx->ctx);
    if (!embd) {
        snprintf(g_error, sizeof(g_error), "failed to get embeddings");
        llama_batch_free(batch);
        free(tokens);
        return NULL;
    }

    // Copy the embedding (llama_get_embeddings returns pointer into context memory)
    int n_embd = ctx->n_embd;
    float *result = malloc(n_embd * sizeof(float));
    memcpy(result, embd, n_embd * sizeof(float));

    *dim = n_embd;

    llama_batch_free(batch);
    free(tokens);
    return result;
}

void llama_embed_free_result(float *result) {
    free(result);
}
