# ActivityTracker — one-command build
#
#   make           Build everything (clone deps, compile, produce binary)
#   make install   Install to ~/.local/
#   make clean     Remove build artifacts
#
# Prerequisites: Xcode Command Line Tools + cmake (brew install cmake)
#   xcode-select --install
#   brew install cmake

PREFIX      ?= $(HOME)/.local
BIN_DIR     := $(PREFIX)/bin
MODEL_DIR   := $(PREFIX)/share/activity-tracker/models
BUILD_DIR   := .build/deps
LLAMA_SRC   := $(BUILD_DIR)/llama.cpp
WHISPER_SRC := $(BUILD_DIR)/whisper.cpp
NPROC       := $(shell sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

# Binaries
LLAMA_EMBED := $(BUILD_DIR)/bin/llama-embedding
WHISPER_CLI := $(BUILD_DIR)/bin/whisper-cli

# Models
EMBED_MODEL := $(MODEL_DIR)/mxbai-embed-large.gguf
WHISPER_MODEL := $(MODEL_DIR)/ggml-small.bin

# Swift
SWIFT_BUILD := swift build -c release
BINARY      := .build/release/ActivityTracker

.PHONY: all install clean deps models run

all: $(BINARY) $(LLAMA_EMBED) $(WHISPER_CLI) models
	@echo ""
	@echo "==> Build complete: $(BINARY)"
	@echo "    Run: make install   (installs to $(PREFIX)/bin)"
	@echo "    Run: make run       (builds and runs)"

install: all
	mkdir -p $(BIN_DIR) $(MODEL_DIR)
	cp $(BINARY) $(BIN_DIR)/activity-tracker
	cp $(LLAMA_EMBED) $(BIN_DIR)/
	cp $(WHISPER_CLI) $(BIN_DIR)/
	cp -n $(EMBED_MODEL) $(MODEL_DIR)/ 2>/dev/null || true
	cp -n $(WHISPER_MODEL) $(MODEL_DIR)/ 2>/dev/null || true
	@echo ""
	@echo "==> Installed to $(BIN_DIR)/activity-tracker"
	@echo "    On first run, default config is written to:"
	@echo "      ~/.config/activity-tracker/config.json"
	@echo ""
	@echo "    Grant permissions in System Settings:"
	@echo "      Privacy → Accessibility       (for window text extraction)"
	@echo "      Privacy → Screen Recording    (for screenshot capture)"

run: all
	$(BINARY)

# --- Swift binary ---

$(BINARY): $(shell find Sources -name '*.swift') Package.swift
	$(SWIFT_BUILD)

# llama.cpp — uses cmake (they dropped the plain Makefile)
$(LLAMA_SRC):
	git clone --depth 1 https://github.com/ggerganov/llama.cpp.git $(LLAMA_SRC)

$(LLAMA_EMBED): $(LLAMA_SRC)
	@echo "==> Building llama.cpp (llama-embedding) …"
	@# Fix: missing <cerrno> include on macOS with Apple Clang 16
	@if ! grep -q '<cerrno>' $(LLAMA_SRC)/ggml/src/gguf.cpp; then \
		sed -i '' '1s/^/#include <cerrno>\n/' $(LLAMA_SRC)/ggml/src/gguf.cpp; \
	fi
	cd $(LLAMA_SRC) && cmake -B build \
		-DLLAMA_BUILD_EXAMPLES=ON \
		-DLLAMA_BUILD_TESTS=OFF \
		-DLLAMA_BUILD_SERVER=OFF \
		-DGGML_METAL=ON
	cd $(LLAMA_SRC) && cmake --build build --target llama-embedding -j$(NPROC)
	mkdir -p $(dir $(LLAMA_EMBED))
	cp $(LLAMA_SRC)/build/bin/llama-embedding $(LLAMA_EMBED)

# --- whisper.cpp (plain Makefile) ---

$(WHISPER_SRC):
	git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git $(WHISPER_SRC)

$(WHISPER_CLI): $(WHISPER_SRC)
	@echo "==> Building whisper.cpp (whisper-cli) …"
	cd $(WHISPER_SRC) && make whisper-cli -j$(NPROC)
	mkdir -p $(dir $(WHISPER_CLI))
	cp $(WHISPER_SRC)/whisper-cli $(WHISPER_CLI)

# --- Models ---

models: $(EMBED_MODEL) $(WHISPER_MODEL)

$(EMBED_MODEL):
	@echo "==> Downloading mxbai-embed-large (~670MB) …"
	mkdir -p $(MODEL_DIR)
	curl -L --progress-bar -o $(EMBED_MODEL) \
		"https://huggingface.co/mixedbread-ai/mxbai-embed-large-v1/resolve/main/gguf/mxbai-embed-large-v1-f16.gguf"

$(WHISPER_MODEL):
	@echo "==> Downloading whisper small (~500MB) …"
	mkdir -p $(MODEL_DIR)
	curl -L --progress-bar -o $(WHISPER_MODEL) \
		"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"

# --- Clean ---

clean:
	rm -rf .build

distclean: clean
	rm -rf $(MODEL_DIR)
