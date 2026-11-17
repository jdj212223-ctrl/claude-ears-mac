#!/bin/sh
# Builds claude-ears (needs Xcode command line tools). Needs whisper-cli + ffmpeg (brew install whisper-cpp ffmpeg).
cd "$(dirname "$0")" && xcrun swiftc -O main.swift -o claude-ears && echo "built $(pwd)/claude-ears"
