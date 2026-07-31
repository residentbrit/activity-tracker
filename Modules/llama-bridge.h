// C bridging header for llama.cpp embedding.
// Exposes only the embedding pathway — model load, encode, extract embeddings, free.

#ifndef ACTIVITY_TRACKER_LLAMA_BRIDGE_H
#define ACTIVITY_TRACKER_LLAMA_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a loaded model + context.
typedef struct llama_embed_ctx llama_embed_ctx;

/// Load a GGUF model and create an embedding context.
/// Returns NULL on failure; check llama_embed_error() for details.
llama_embed_ctx* llama_embed_load(const char *model_path);

/// Free the embedding context and unload the model.
void llama_embed_free(llama_embed_ctx *ctx);

/// Embed a text string. Returns a float array of `dim` floats.
/// Caller must free the result with llama_embed_free_result().
/// Returns NULL on failure.
float* llama_embed_run(llama_embed_ctx *ctx, const char *text, int *dim);

/// Free the result from llama_embed_run().
void llama_embed_free_result(float *result);

/// Get the last error message. Returns "" if no error.
const char* llama_embed_error(void);

/// Get the embedding dimension for a loaded context.
int llama_embed_dim(llama_embed_ctx *ctx);

#ifdef __cplusplus
}
#endif

#endif // ACTIVITY_TRACKER_LLAMA_BRIDGE_H
