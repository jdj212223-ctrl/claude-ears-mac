# Claude Ears (Mac) 👂

Lets Claude **hear what the Mac is playing** while it controls the computer: a video, a game, a notification, a
creepy song. It's an MCP server with a `listen` tool.

`listen(seconds)` returns:
- the **speech** as text (whisper.cpp, on this Mac)
- **sound labels**: `[silence]`, `[quiet]`, `[loud]`, `[sudden loud sound]`, and whisper's own `[music]`, `[scream]`,
  `[laugh]`, `[applause]`...
- a **spectrogram picture**: time left→right, pitch bottom→top, brightness = loudness. Claude can't take raw audio, but
  it can see this: beats, melodies, slowed-down audio, screams, silence.

## Privacy rules (built in)
- Only the Mac's **sound output** (ScreenCaptureKit). **Never the microphone.**
- **Pauses during calls**: if any app is using the microphone (FaceTime, Zoom, Discord...), it refuses to listen.
- A **"Claude is listening"** notification every time it listens.
- **Nothing is kept**: the recording is deleted right after it's transcribed. Nothing is sent anywhere.
- **Off switch**: the `ears_off` tool, or create `~/Library/Application Support/claude-ears/OFF`.

## Set up
```
./build.sh
claude mcp add --scope user ears -- /Volumes/important/claude-ears-mac/claude-ears mcp
```
The app that runs it (Claude or Terminal) needs **Screen & System Audio Recording** permission
(System Settings → Privacy & Security). Uses `/Volumes/important/claude-player/models/ggml-base.en.bin`; set
`CLAUDE_EARS_MODEL` for another whisper model.

Try it without MCP: `./claude-ears listen 8 spectrogram.png`
