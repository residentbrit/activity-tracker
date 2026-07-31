#!/bin/bash
# Thin wrapper — just runs `make all`.
# For a full build from scratch: make
# For install: make install
set -e
cd "$(dirname "$0")"
exec make all