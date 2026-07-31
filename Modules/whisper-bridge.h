// C bridging header for whisper.cpp transcription.

#ifndef ACTIVITY_TRACKER_WHISPER_BRIDGE_H
#define ACTIVITY_TRACKER_WHISPER_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a loaded whisper model.
typedef struct whisper_ctx whisper_ctx;

/// Load a whisper model from a GGML file.
/// Returns NULL on failure.
whisper_ctx* whisper_load(const char *model_path);

/// Transcribe 16kHz mono PCM data (Int16 samples).
/// Returns the transcript as a malloc'd string, or NULL on failure.
/// Caller must free with whisper_free_transcript().
char* whisper_transcribe(whisper_ctx *ctx, const int16_t *samples, int n_samples);

/// Free a transcript returned by whisper_transcribe().
void whisper_free_transcript(char *transcript);

/// Free the whisper context.
void whisper_free_ctx(whisper_ctx *ctx);

#ifdef __cplusplus
}
#endif

#endif // ACTIVITY_TRACKER_WHISPER_BRIDGE_H
