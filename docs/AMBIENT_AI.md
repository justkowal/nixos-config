# Ambient AI Integration Suite Technical Manual

This document is a 100% exhaustive reference manual for the **Ambient AI Integration Suite** running on NixOS.

The system completely replaces legacy voice assistant gimmicks with **invisible, proactive, background-first AI daemons** powered by local Ollama models (accelerated via AMD ROCm on the Radeon RX 6700 XT).

---

## 1. System Infrastructure & Backend Configuration (`modules/ai.nix`)

### 1. Ollama Daemon Service (`services.ollama`)
- **Package**: `pkgs.ollama-rocm`
- **GPU Architecture Target**: `HSA_OVERRIDE_GFX_VERSION = "10.3.0"`, `rocmOverrideGfx = "10.3.0"` (Navi 22 RX 6700 XT override).
- **Concurrency**: `OLLAMA_NUM_PARALLEL = "2"`.
- **Pre-Loaded Model List (`loadModels`)**:
  - `nomic-embed-text`
  - `hf.co/huihui-ai/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-GGUF`
  - `hf.co/huihui-ai/Huihui-gemma-4-E4B-it-qat-q4_0-unquantized-abliterated-GGUF`
  - `hf.co/huihui-ai/Huihui-gemma-4-12B-it-qat-q4_0-unquantized-abliterated-GGUF`

### 2. Local SearXNG Privacy Meta-Search Engine (`services.searx`)
- **Address & Port**: `127.0.0.1:8888`
- **Secret Key**: `nixos-local-searxng-ai-secret`
- **Search Settings**: `safe_search = 0`, `autocomplete = "google"`, formats `["html", "json"]`.
- **Engines Configured**: DuckDuckGo (`ddg`), Google (`g`), GitHub (`gh`), Wikipedia (`wp`).

### 3. Open-WebUI RAG Interface (`services.open-webui`)
- **Address & Port**: `127.0.0.1:11111`
- **Ollama API Base**: `http://127.0.0.1:11434`
- **Auth**: `WEBUI_AUTH = "false"`, `ENABLE_SIGNUP = "true"`.
- **Vector Database**: `VECTOR_DB = "chroma"`.
- **Embedding Engine**: `RAG_EMBEDDING_ENGINE = "ollama"`, model `nomic-embed-text`, `RAG_TOP_K = "5"`, `RAG_RELEVANCE_THRESHOLD = "0.1"`, `ENABLE_RAG_HYBRID_SEARCH = "True"`.
- **Web Search RAG Integration**: `ENABLE_RAG_WEB_SEARCH = "True"`, engine `searxng`, query URL `http://127.0.0.1:8888/search?q=<query>`.

---

## 2. Model Tiering Strategy (`hosts/desktop/home-ai.nix`)

All ambient services select local Gemma 4 models according to target latency constraints:

| Tier | Quantized Model Identifier | Response Time | Assigned Integrations / Tasks |
| :--- | :--- | :--- | :--- |
| **E2B** (Instant) | `hf.co/huihui-ai/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-GGUF` | ~1.0 sec | Smart Clipboard actions, Waybar widget, Health Advisor, Spotlight AI search fallback |
| **E4B** (Mid-tier) | `hf.co/huihui-ai/Huihui-gemma-4-E4B-it-qat-q4_0-unquantized-abliterated-GGUF` | ~3.0 sec | Git prepare-commit-msg hook, Smart File Auto-Organizer, Notification Digest timer |
| **12B** (Deep Analysis) | `hf.co/huihui-ai/Huihui-gemma-4-12B-it-qat-q4_0-unquantized-abliterated-GGUF` | ~8.0 sec | Interactive Rofi AI popup, Nushell `ai-papa`, `ai-debug` system log diagnosis |

---

## 3. Integrated Ambient Services (`hosts/desktop/home-ai.nix`)

### 📋 1. Smart Context-Aware Clipboard
- **Daemon Script**: `~/.config/ai/clipboard_context.sh`
- **Systemd Service**: `ai-clipboard-context.service` (runs continuously in background session, restarts on exit after 10s).
- **Classification Engine**:
  - Ignores snippets < 20 chars.
  - Matches `https?://` -> `url`
  - Matches email patterns -> `email`
  - Matches `(error|exception|traceback|panic|segfault)` -> `error`
  - Matches programming syntax (`def`, `fn`, `func`, `class`, `import`, `{`, `;`) -> `code`
  - Matches long text (>100 chars) -> `prose`
- **Actions Menu (Rofi Modal)**:
  - Code: **Format Code** (removes code fences), **Explain Code** (2-3 sentence summary)
  - URL: **Summarize Page**
  - Error: **Diagnose Error** (explains cause and fix command)
  - Prose: **Summarize**, **Translate** (EN ↔ PL)
- Action execution updates `wl-paste` clipboard + sends notification toast via `notify-send`.

### 🩺 2. Proactive System Health Advisor
- **Script**: `~/.config/ai/health_advisor.sh`
- **Systemd Service & Timer**: `ai-health-advisor.service` & `ai-health-advisor.timer` (runs every 5 minutes, oneshot).
- **Metric Extraction**:
  - RAM %: `free -m` calculation.
  - Disk %: `df /` root partition usage.
  - CPU Temp: Scans `/sys/class/hwmon/hwmon*/name` for `k10temp`.
  - GPU Temp: Scans `/sys/class/drm/card1/device/hwmon/temp1_input`.
  - System Load: `uptime` load average vs `$(nproc) * 2`.
- **Threshold Triggers**:
  - RAM > 85%, Disk > 90%, CPU > 85°C, GPU > 90°C, Load > 2× cores.
- **Behavior**: Completely silent when metrics are healthy. When thresholds are breached, collects top CPU/RAM processes via `ps aux` and queries E2B LLM for a 1-sentence diagnostic notification.

### 📁 3. Smart File Auto-Organizer
- **Daemon Script**: `~/.config/ai/file_organizer_daemon.sh`
- **Systemd Service**: `ai-file-organizer.service` (background daemon).
- **Watcher**: `inotifywait -m -e close_write,moved_to ~/Downloads`.
- **Safety Rules**:
  - Settles for 5 seconds to allow active downloads to finish writing.
  - Skips hidden dotfiles (`.*`).
  - Skips files > 100MB (`MAX_FILE_MB = 100`).
  - Skips protected keywords: `cyberpunk`, `repack`, `dodi`, `fitgirl`, `steam`, `game`, `games`, `wine`, `lutris`, `heroic`.
- **Classification Hierarchy**:
  - Fast-path extensions: `.pdf` -> `Documents/PDFs`, `.md`/`.txt` -> `Documents/Notes`, `.docx`/`.odt` -> `Documents/Docs`, `.png`/`.jpg` -> `Pictures`, `.zip`/`.7z` -> `Downloads/Archives`, `.appimage`/`.deb` -> `Downloads/Installers`, `.fcstd`/`.stl`/`.step` -> `CAD`, `.mp4`/`.mkv` -> `Media/Videos`, `.mp3`/`.flac` -> `Media/Audio`.
  - Ambiguous files fallback to E4B LLM JSON classification (`{"category": "..."}`).
- Moves files to `~/<category>/`, logs transaction to `~/.local/state/ai-organize.log`, and supports manual `--undo` restoration.

### ✨ 4. Contextual Waybar AI Widget
- **Script**: `~/.config/waybar/scripts/ai_ambient.sh`
- **Poll Schedule**: Waybar module `custom/ai-ambient` calls script every 300 seconds.
- **Context Injection**: Reads uptime, RAM %, disk %, active Hyprland workspace count, and last git commit time in `/etc/nixos`.
- **Rotating Topics**: Rotates category based on minute (`MINUTE / 5 % 5`):
  1. Productivity tip for Linux developer.
  2. NixOS tip or fact.
  3. Time-aware suggestion.
  4. Motivational developer quote.
  5. System metric observation.
- Output cached to `/tmp/waybar_ai_ambient_cache` (TTL 290s) to prevent redundant inference.

### 🔔 5. Scheduled Notification Digest
- **Script**: `~/.config/ai/notification_digest.sh`
- **Systemd Service & Timer**: `ai-notification-digest.service` & `ai-notification-digest.timer` (runs every 30 minutes, oneshot).
- **Behavior**: Calls `swaync-client -s` to fetch unread notification JSON history. If notifications exist, passes recent 30 notifications to E4B LLM to compile an executive bulleted digest toast.

### 📝 6. AI Conventional Commit Generator
- **Script**: `~/.config/ai/git-prepare-commit-msg.sh`
- **Git Hook**: Declaratively bound via Home Manager `programs.git.hooks.prepare-commit-msg`.
- **Behavior**: Triggered automatically on `git commit`. Reads `git diff --cached`, formats prompt requesting Conventional Commit standard (`type(scope): description`), queries E4B model, strips markdown code fences, and prepends suggested commit text into `COMMIT_MSG_FILE`.

### 🔍 7. Spotlight Search AI Fallback
- **Script**: `~/.config/hypr/scripts/spotlight.sh` (Triggered via `Super+D` or `Super+Space`).
- **Unified Pipeline**:
  1. Search installed desktop applications.
  2. Search user files & directories up to depth 3 (`fd`).
  3. Check vector prefix (`v:`, `vec:`, `sem:`).
  4. Check explicit AI prefixes (`?`, `ai:` -> E2B, `ai-task:` -> E4B, `ai-papa:` -> 12B).
  5. Check web prefixes (`g:`, `web:` -> SearXNG `:8888`).
  6. Deep filesystem search fallback.
  7. **AI Instant Fallback**: If no application or file path matches the query, queries E2B LLM for a 1-2 sentence quick answer toast + copies answer to clipboard before opening web search.

---

## 4. Shell Helper Commands (Nushell `hosts/desktop/home-ai.nix`)

Configured in `programs.nushell.extraConfig`:

- **`ai <prompt>`**: Fast shell assistant using E2B model.
- **`ai-task <prompt>`**: Task & code assistant using E4B model.
- **`ai-papa <prompt>`**: Architectural analysis using 12B model.
- **`ai-debug`**: Fetches recent `journalctl -p err..emerg -n 25` error logs and queries 12B model for root cause analysis and terminal fix commands.
- **`git-ai`**: Interactive Conventional Commit generator for staged git changes.
- **`ai-organize [dir] [--dry-run | --undo]`**: Triggers Python file organizer or reverts log.
- **`pdf-qa <file.pdf> [question]`**: Runs RAG over PDF text extracted via `pdftotext`.
- **`vector-search <query>`**: Searches `~/.local/share/home_vectors.json` using Cosine Vector Similarity (embedded via `nomic-embed-text`) + Keyword matching score.
- **`clip-search <query>`**: Searches vector-embedded clipboard history (`~/.local/share/clipboard_vectors.json`).

---

## 5. Systemd User Units Summary

```ini
ai-clipboard-daemon.service  # Vector embedding clipboard watcher daemon
ai-clipboard-context.service # Context-aware notification action daemon
ai-file-organizer.service    # Downloads inotifywait watcher daemon
ai-health-advisor.timer      # System metrics monitor (5 min timer)
ai-notification-digest.timer # SwayNC notification digest (30 min timer)
ai-vector-indexer.timer      # Home directory vector RAG indexer (daily timer)
```
