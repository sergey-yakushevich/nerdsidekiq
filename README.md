<p align="center">
  <img src="assets/logo/nerdsidekiq-logo-pro.png" width="160" alt="NerdSidekiq logo">
</p>

<h1 align="center">NerdSidekiq</h1>

<p align="center"><b>Live AI answers in your interview.</b><br>
Records both sides of the call, transcribes locally, and streams answer hints from your own Claude account — before you finish saying "great question".</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.4%2B-black" alt="macOS 14.4+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-native-black" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT license">
</p>

<p align="center">
  <img src="assets/screenshot.png" width="720" alt="NerdSidekiq during a live interview">
</p>

## Features

- 🎧 **Hears both sides** — your mic and the call audio (Zoom, Meet, anything), via a Core Audio process tap. Your audio devices are never touched.
- 📝 **Local transcription** — whisper.cpp on-device, free and private. Audio never leaves your Mac.
- 🤖 **Automatic live answers** — questions are detected as they are asked; the answer streams into a floating always-on-top window with live captions and syntax-highlighted code. No hotkeys.
- 🧠 **Your own Claude** — one-time OAuth to your Claude account, pick any model per task. No API keys to manage.
- 📁 **Transcripts where you want them** — one folder per call: audio, transcript, AI summary with an AI-generated title.
- 🧭 **First-run wizard** — permissions, Claude authorization, models, folders. Two minutes and you are set.

## Install

1. Grab **`NerdSidekiq.dmg`** from [Releases](../../releases) and drag the app into Applications.
2. Install the two local dependencies:
   ```sh
   brew install whisper-cpp ffmpeg anthropics/tap/ant
   ```
3. Open the app — the setup wizard walks you through microphone + system-audio permissions, Claude authorization (browser, one click), model choice, and your transcript folder.

## Usage

1. Click **Start Call** before your meeting.
2. Talk. Captions and answers appear in the floating window automatically whenever the interviewer asks something substantive.
3. Click **Finish Call** — you get a titled transcript + summary in your transcript folder.

Settings (⌘,) let you change models (e.g. a cheaper model for the rolling summary), the transcript folder, and toggle live answers.

## Build from source

```sh
git clone https://github.com/sergey-yakushevich/nerdsidekiq
cd nerdsidekiq
python3 -m venv .venv && .venv/bin/pip install anthropic
cd overlay && npm install && cd ..
./build.sh          # → build/NerdSidekiq.app
./make-dmg.sh       # → dist/NerdSidekiq.dmg (optional installer)
```

`./demo.sh en` runs a full self-test with a synthetic voice.

## How it works

Swift app (audio capture, UI) → Python pipeline (whisper.cpp transcription, Claude calls via the Anthropic SDK) → Electron overlay (captions + streamed answers). Claude usage bills to your own account; transcription costs nothing.

## License

MIT — free and open source. Use it, fork it, land the job.
