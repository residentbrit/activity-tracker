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
LLAMA_EMBED  := $(BUILD_DIR)/bin/llama-embedding
LLAMA_SERVER := $(BUILD_DIR)/bin/llama-server
WHISPER_CLI := $(BUILD_DIR)/bin/whisper-cli

# Models
EMBED_MODEL := $(MODEL_DIR)/mxbai-embed-large.gguf
WHISPER_MODEL := $(MODEL_DIR)/ggml-small.bin

# Swift
SWIFT_BUILD := swift build -c release
BINARY      := .build/release/ActivityTracker

.PHONY: all install clean deps models run backfill migrate-screenpipe migrate-screenpipe-embed daemon-install daemon-uninstall embedserver-install harvest-chat harvest-install harvest-embed

all: $(BINARY) $(LLAMA_EMBED) $(LLAMA_SERVER) $(WHISPER_CLI) models
	@echo ""
	@echo "==> Build complete: $(BINARY)"
	@echo "    Run: make install   (installs to $(PREFIX)/bin)"
	@echo "    Run: make run       (builds and runs)"

install: all
	mkdir -p $(BIN_DIR) $(MODEL_DIR)
	# Stop the daemon BEFORE replacing the binary — replacing a signed binary
	# while it runs causes macOS to SIGKILL it ("Code Signature Invalid").
	launchctl unload $(HOME)/Library/LaunchAgents/com.activitytracker.collector.plist 2>/dev/null || true
	cp $(BINARY) $(BIN_DIR)/activity-tracker
	codesign --force --sign "ActivityTracker Dev" $(BIN_DIR)/activity-tracker 2>/dev/null || true
	cp $(LLAMA_EMBED) $(BIN_DIR)/
	cp $(LLAMA_SERVER) $(BIN_DIR)/
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

daemon-install: install
	mkdir -p $(HOME)/.local/share/activity-tracker/logs
	sed 's|%HOME%|$(HOME)|g' launchd/com.activitytracker.collector.plist > $(HOME)/Library/LaunchAgents/com.activitytracker.collector.plist
	launchctl load $(HOME)/Library/LaunchAgents/com.activitytracker.collector.plist
	@echo ""
	@echo "==> Daemon installed and started"
	@echo "    Monitor: tail -f $(HOME)/.local/share/activity-tracker/logs/collector.log"
	@echo "    Status:  launchctl list com.activitytracker.collector"
	@echo "    Stop:    launchctl unload $(HOME)/Library/LaunchAgents/com.activitytracker.collector.plist"

daemon-uninstall:
	launchctl unload $(HOME)/Library/LaunchAgents/com.activitytracker.collector.plist || true
	launchctl unload $(HOME)/Library/LaunchAgents/com.activitytracker.embedserver.plist || true
	launchctl unload $(HOME)/Library/LaunchAgents/com.activitytracker.harvest.plist || true
	rm -f $(HOME)/Library/LaunchAgents/com.activitytracker.collector.plist
	rm -f $(HOME)/Library/LaunchAgents/com.activitytracker.embedserver.plist
	rm -f $(HOME)/Library/LaunchAgents/com.activitytracker.harvest.plist
	@echo "==> Daemons stopped and removed"

embedserver-install: install
	mkdir -p $(HOME)/.local/share/activity-tracker/logs
	sed 's|%HOME%|$(HOME)|g' launchd/com.activitytracker.embedserver.plist > $(HOME)/Library/LaunchAgents/com.activitytracker.embedserver.plist
	launchctl load $(HOME)/Library/LaunchAgents/com.activitytracker.embedserver.plist
	@echo ""
	@echo "==> Embed server installed and started (port 8080)"
	@echo "    Monitor: tail -f $(HOME)/.local/share/activity-tracker/logs/embedserver.log"
	@echo "    Status:  launchctl list com.activitytracker.embedserver"

run: all
	$(BINARY)

backfill:
	./scripts/backfill_embeddings.py

migrate-screenpipe:
	./scripts/migrate_screenpipe.py

migrate-screenpipe-embed:
	./scripts/backfill_embeddings.py --trigger screenpipe_import

# --- VS Code Copilot Chat harvest ---

harvest-chat:
	/usr/bin/python3 scripts/harvest_vscode_chat.py

harvest-embed:
	./scripts/backfill_embeddings.py --trigger copilot_chat_import

harvest-install:
	mkdir -p $(HOME)/.local/share/activity-tracker/logs
	sed 's|%HOME%|$(HOME)|g' launchd/com.activitytracker.harvest.plist > $(HOME)/Library/LaunchAgents/com.activitytracker.harvest.plist
	launchctl unload $(HOME)/Library/LaunchAgents/com.activitytracker.harvest.plist 2>/dev/null || true
	launchctl load $(HOME)/Library/LaunchAgents/com.activitytracker.harvest.plist
	@echo ""
	@echo "==> Chat harvest job installed (runs hourly)"
	@echo "    Manual run:  make harvest-chat"
	@echo "    Embed after: make harvest-embed"

# --- Swift binary ---

$(BINARY): $(shell find Sources -name '*.swift') Package.swift
	$(SWIFT_BUILD)

# llama.cpp — uses cmake (they dropped the plain Makefile)
$(LLAMA_SRC):
	git clone --depth 1 https://github.com/ggerganov/llama.cpp.git $(LLAMA_SRC)

$(LLAMA_EMBED): $(LLAMA_SRC)
	@echo "==> Building llama.cpp (llama-embedding + llama-server) …"
	@# Fix: missing <cerrno> include on macOS with Apple Clang 16
	@if ! grep -q '<cerrno>' $(LLAMA_SRC)/ggml/src/gguf.cpp; then \
		sed -i '' '1s/^/#include <cerrno>\n/' $(LLAMA_SRC)/ggml/src/gguf.cpp; \
	fi
	cd $(LLAMA_SRC) && cmake -B build \
		-DLLAMA_BUILD_EXAMPLES=ON \
		-DLLAMA_BUILD_TESTS=OFF \
		-DLLAMA_BUILD_SERVER=ON \
		-DGGML_METAL=ON \
		-DLLAMA_CURL=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=ON
	cd $(LLAMA_SRC) && cmake --build build --target llama-embedding llama-server -j$(NPROC)
	mkdir -p $(dir $(LLAMA_EMBED))
	cp $(LLAMA_SRC)/build/bin/llama-embedding $(LLAMA_EMBED)

$(LLAMA_SERVER): $(LLAMA_EMBED)
	cp $(LLAMA_SRC)/build/bin/llama-server $(LLAMA_SERVER)

# --- whisper.cpp (uses cmake — they also dropped the plain Makefile) ---

$(WHISPER_SRC):
	git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git $(WHISPER_SRC)

$(WHISPER_CLI): $(WHISPER_SRC)
	@echo "==> Building whisper.cpp (whisper-cli) …"
	@# Fix: same errno bug as llama.cpp — they share ggml
	@if ! grep -q '<cerrno>' $(WHISPER_SRC)/ggml/src/gguf.cpp; then \
		sed -i '' '1s/^/#include <cerrno>\n/' $(WHISPER_SRC)/ggml/src/gguf.cpp; \
	fi
	cd $(WHISPER_SRC) && cmake -B build
	cd $(WHISPER_SRC) && cmake --build build --target whisper-cli -j$(NPROC)
	mkdir -p $(dir $(WHISPER_CLI))
	cp $(WHISPER_SRC)/build/bin/whisper-cli $(WHISPER_CLI)

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
