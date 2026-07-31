// Thin C wrapper around whisper.cpp's transcription pathway.

#include "whisper-bridge.h"
#include "whisper.h"

#include <stdlib.h>
#include <string.h>

struct whisper_ctx {
    struct whisper_context *ctx;
};

whisper_ctx* whisper_load(const char *model_path) {
    struct whisper_context_params params = whisper_context_default_params();
    struct whisper_context *ctx = whisper_init_from_file_with_params(model_path, params);
    if (!ctx) return NULL;

    whisper_ctx *w = calloc(1, sizeof(whisper_ctx));
    w->ctx = ctx;
    return w;
}

char* whisper_transcribe(whisper_ctx *w, const int16_t *samples, int n_samples) {
    if (!w || !samples || n_samples <= 0) return NULL;

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.no_timestamps = true;
    params.language = "en";
    params.n_threads = 4;

    if (whisper_full(w->ctx, params, samples, n_samples) != 0) {
        return NULL;
    }

    // Collect all segments into one string
    int n_segments = whisper_full_n_segments(w->ctx);
    if (n_segments <= 0) return NULL;

    // Calculate total length
    size_t total_len = 0;
    for (int i = 0; i < n_segments; i++) {
        total_len += strlen(whisper_full_get_segment_text(w->ctx, i)) + 2; // +2 for "\n\0"
    }

    char *result = calloc(total_len, 1);
    if (!result) return NULL;

    for (int i = 0; i < n_segments; i++) {
        const char *seg = whisper_full_get_segment_text(w->ctx, i);
        strcat(result, seg);
        if (i < n_segments - 1) strcat(result, " ");
    }

    return result;
}

void whisper_free_transcript(char *transcript) {
    free(transcript);
}

void whisper_free_ctx(whisper_ctx *w) {
    if (!w) return;
    whisper_free(w->ctx);
    free(w);
}
