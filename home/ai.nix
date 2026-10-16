{ config, pkgs, lib, ... }: {

  # ═══════════════════════════════════════════════════════════════════════
  # Ambient AI Integration Suite
  # Background-first, invisible, proactive AI integrations powered by
  # local Ollama models. No voice I/O, no chat UIs — just a system
  # that quietly "gets it."
  #
  # Model Tiers:
  #   E2B  — instant (~1s) for clipboard, waybar, health, search fallback
  #   E4B  — mid-tier (~3s) for commit messages, file classification, digests
  #   12B  — deep analysis, used only in explicit shell commands
  # ═══════════════════════════════════════════════════════════════════════

  # ─── Rofi AI Popup ─────────────────────────────────────────────────────

  # Markdown to GTK Pango Markup Converter for SwayNC Notifications
  xdg.configFile."ai/md_to_pango.py" = {
    executable = true;
    text = builtins.readFile ./ai/md_to_pango.py;
  };

  # Interactive Rofi AI Popup with Handoff to Open-WebUI
  xdg.configFile."hypr/scripts/rofi_ai.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      PROMPT="$1"
      if [ -z "$PROMPT" ]; then
        PROMPT=$(${pkgs.rofi}/bin/rofi -dmenu -i -p "󰚩 AI Assistant" -font "Outfit 12" -theme-str 'window {width: 650px;}')
      fi
      [ -z "$PROMPT" ] && exit 0

      TAGS=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/tags 2>/dev/null || echo '{}')
      PREF_MODEL="hf.co/huihui-ai/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-GGUF"
      TARGET_MODEL=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r --arg pref "$PREF_MODEL" '.models[]? | select(.name != "nomic-embed-text:latest") | .name | select(contains($pref))' | head -n 1)
      FIRST_MODEL=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r '.models[]? | select(.name != "nomic-embed-text:latest") | .name' | head -n 1)
      MODEL="''${TARGET_MODEL:-''${FIRST_MODEL:-$PREF_MODEL}}"

      ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:rofi-ai "󰚩 AI Assistant" "Thinking with model: $MODEL..." -i dialog-information

      # Inject system metrics if query mentions system info
      SYS_METRICS=""
      PROMPT_LOWER=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')
      if [[ "$PROMPT_LOWER" =~ "ram" ]] || [[ "$PROMPT_LOWER" =~ "memory" ]] || [[ "$PROMPT_LOWER" =~ "disk" ]] || [[ "$PROMPT_LOWER" =~ "cpu" ]] || [[ "$PROMPT_LOWER" =~ "system" ]]; then
        MEM_INFO=$(free -h | awk '/Mem:/ {print $3 "/" $2}')
        DISK_INFO=$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')
        CPU_LOAD=$(uptime | awk -F'load average:' '{print $2}')
        SYS_METRICS="[System: RAM $MEM_INFO, Disk $DISK_INFO, Load$CPU_LOAD]\n"
      fi

      FULL_PROMPT="$SYS_METRICS$PROMPT"
      PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg m "$MODEL" --arg p "$FULL_PROMPT" '{model: $m, prompt: $p, stream: false}')
      RAW_RES=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/generate -d "$PAYLOAD")
      RESPONSE=$(echo "$RAW_RES" | ${pkgs.jq}/bin/jq -r '.response // empty')

      if [ -z "$RESPONSE" ] || [ "$RESPONSE" = "null" ]; then
        ${pkgs.libnotify}/bin/notify-send "AI Error" "Failed to get response from Ollama." -i dialog-error
        exit 1
      fi

      CONVERSATION="User: $PROMPT\nAssistant: $RESPONSE\n"

      while true; do
        CHOICE=$(echo -e "󰭻 Ask Follow-up Question\n󰆏 Copy Response to Clipboard\n󰖟 Open in Open-WebUI\n󰅖 Close" | ${pkgs.rofi}/bin/rofi -dmenu -i -p "AI Response" -mesg "$RESPONSE" -font "Outfit 11" -theme-str 'window {width: 850px;} message {border: 2px; border-radius: 12px; padding: 12px; margin: 0px 0px 10px 0px;} textbox {wrap: true;} listview {lines: 4;} element {padding: 8px;}')

        if [ -z "$CHOICE" ] || [[ "$CHOICE" =~ "Close" ]]; then
          exit 0
        elif [[ "$CHOICE" =~ "Copy Response" ]]; then
          echo "$RESPONSE" | ${pkgs.wl-clipboard}/bin/wl-copy
          ${pkgs.libnotify}/bin/notify-send "AI Assistant" "Response copied to clipboard!"
          exit 0
        elif [[ "$CHOICE" =~ "Open-WebUI" ]]; then
          ENCODED_PROMPT=$(echo -n "$PROMPT" | ${pkgs.jq}/bin/jq -sRr @uri)
          WEBUI_URL="http://127.0.0.1:11111/?q=$ENCODED_PROMPT"
          ( ${pkgs.xdg-utils}/bin/xdg-open "$WEBUI_URL" || ${pkgs.firefox}/bin/firefox "$WEBUI_URL" ) >/dev/null 2>&1 & disown
          exit 0
        else
          TYPED_REPLY=$(echo "$CHOICE" | ${pkgs.gnused}/bin/sed -E 's/^\s*󰭻\s*Ask Follow-up Question.*\s*//')
          if [ -z "$TYPED_REPLY" ]; then
            TYPED_REPLY=$(${pkgs.rofi}/bin/rofi -dmenu -i -p "Follow-up Question" -font "Outfit 12" -theme-str 'window {width: 650px;}')
          fi
          [ -z "$TYPED_REPLY" ] && exit 0

          CONVERSATION="$CONVERSATION User: $TYPED_REPLY\nAssistant:"
          NEXT_PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg m "$MODEL" --arg p "$CONVERSATION" '{model: $m, prompt: $p, stream: false}')
          NEXT_RAW=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/generate -d "$NEXT_PAYLOAD")
          RESPONSE=$(echo "$NEXT_RAW" | ${pkgs.jq}/bin/jq -r '.response // empty')
          CONVERSATION="$CONVERSATION $RESPONSE\n"
        fi
      done
    '';
  };

  # ─── AI Screenshot OCR & Visual Analysis ───────────────────────────────

  xdg.configFile."hypr/scripts/ai_ocr_screenshot.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      TEMP_IMG="/tmp/ai_ocr_$(date +%s).png"
      ${pkgs.grim}/bin/grim -g "$(${pkgs.slurp}/bin/slurp)" "$TEMP_IMG"
      ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i camera-shutter 2>/dev/null

      if [ -f "$TEMP_IMG" ]; then
        ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:ai-vision "󰹑 Vision AI" "Analyzing screenshot contents..." -i image-x-generic

        BASE64_IMG=$(${pkgs.coreutils}/bin/base64 -w 0 "$TEMP_IMG")
        TAGS=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/tags 2>/dev/null || echo '{}')
        PREF_MODEL="hf.co/huihui-ai/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-GGUF"
        TARGET_MODEL=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r --arg pref "$PREF_MODEL" '.models[]? | select(.name != "nomic-embed-text:latest") | .name | select(contains($pref))' | head -n 1)

        PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg m "$TARGET_MODEL" --arg img "$BASE64_IMG" '{model: $m, prompt: "Analyze, describe, and extract text/code from this screenshot:", images: [$img], stream: false}')
        RAW_RES=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/generate -d "$PAYLOAD")
        RESPONSE=$(echo "$RAW_RES" | ${pkgs.jq}/bin/jq -r '.response // empty')

        if [ -n "$RESPONSE" ] && [ "$RESPONSE" != "null" ]; then
          CONVERSATION="User: [Screenshot Image]\nAssistant: $RESPONSE\n"
          while true; do
            CHOICE=$(echo -e "󰭻 Ask Follow-up Question about Screenshot\n󰆏 Copy Analysis to Clipboard\n󰖟 Open in Open-WebUI\n󰅖 Close" | ${pkgs.rofi}/bin/rofi -dmenu -i -p "AI Screenshot Analysis" -mesg "$RESPONSE" -font "Outfit 11" -theme-str 'window {width: 850px;} message {border: 2px; border-radius: 12px; padding: 12px; margin: 0px 0px 10px 0px;} textbox {wrap: true;} listview {lines: 4;} element {padding: 8px;}')

            if [ -z "$CHOICE" ] || [[ "$CHOICE" =~ "Close" ]]; then exit 0
            elif [[ "$CHOICE" =~ "Copy Analysis" ]]; then
              echo "$RESPONSE" | ${pkgs.wl-clipboard}/bin/wl-copy
              ${pkgs.libnotify}/bin/notify-send "AI Screenshot" "Analysis copied to clipboard!"
              exit 0
            elif [[ "$CHOICE" =~ "Open-WebUI" ]]; then
              ENCODED_PROMPT=$(echo -n "Analyze screenshot: $RESPONSE" | ${pkgs.jq}/bin/jq -sRr @uri)
              ( ${pkgs.xdg-utils}/bin/xdg-open "http://127.0.0.1:11111/?q=$ENCODED_PROMPT" ) >/dev/null 2>&1 & disown
              exit 0
            else
              TYPED_REPLY=$(echo "$CHOICE" | ${pkgs.gnused}/bin/sed -E 's/^\s*󰭻\s*Ask Follow-up Question.*\s*//')
              [ -z "$TYPED_REPLY" ] && TYPED_REPLY=$(${pkgs.rofi}/bin/rofi -dmenu -i -p "Follow-up Question" -font "Outfit 12" -theme-str 'window {width: 650px;}')
              [ -z "$TYPED_REPLY" ] && exit 0

              CONVERSATION="$CONVERSATION User: $TYPED_REPLY\nAssistant:"
              NEXT_PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg m "$TARGET_MODEL" --arg p "$CONVERSATION" '{model: $m, prompt: $p, stream: false}')
              NEXT_RAW=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/generate -d "$NEXT_PAYLOAD")
              RESPONSE=$(echo "$NEXT_RAW" | ${pkgs.jq}/bin/jq -r '.response // empty')
              CONVERSATION="$CONVERSATION $RESPONSE\n"
            fi
          done
        else
          ${pkgs.libnotify}/bin/notify-send "AI Screenshot Error" "Failed to get analysis from Ollama." -i dialog-error
        fi
        rm -f "$TEMP_IMG"
      fi
    '';
  };

  # ─── Smart AI File & Directory Organizer (manual invocation) ───────────

  xdg.configFile."hypr/scripts/ai_organize.py" = {
    executable = true;
    text = builtins.readFile ./ai/ai_organize.py;
  };

  # ─── AI Clipboard Manager (Vector-embedded persistent history) ─────────

  xdg.configFile."ai/clipboard_daemon.py" = {
    executable = true;
    text = builtins.readFile ./ai/clipboard_daemon.py;
  };

  # ─── PDF Q&A Tool ──────────────────────────────────────────────────────

  xdg.configFile."ai/pdf_qa.py" = {
    executable = true;
    text = builtins.readFile ./ai/pdf_qa.py;
  };

  # ─── Notification Digest ───────────────────────────────────────────────

  xdg.configFile."ai/notification_digest.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      OLLAMA_URL="http://127.0.0.1:11434/api/generate"
      PREF_MODEL="hf.co/huihui-ai/Huihui-gemma-4-E4B-it-qat-q4_0-unquantized-abliterated-GGUF"
      TAGS=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/tags 2>/dev/null || echo '{}')
      TARGET=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r --arg pref "$PREF_MODEL" '.models[]? | select(.name != "nomic-embed-text:latest") | .name | select(contains($pref))' | head -n 1)
      FIRST=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r '.models[]? | select(.name != "nomic-embed-text:latest") | .name' | head -n 1)
      MODEL="''${TARGET:-''${FIRST:-$PREF_MODEL}}"

      # Skip scheduled execution if GPU is busy (> 15%) or CPU load > 35% or heavy workload active
      GPU_BUSY=$(cat /sys/class/drm/card1/device/gpu_busy_percent 2>/dev/null || echo 0)
      LOAD_1M=$(uptime | awk -F'load average:' '{print $2}' | awk -F, '{print $1}' | tr -d ' ')
      NPROC=$(nproc)
      LOAD_PCT=$(echo "$LOAD_1M * 100 / $NPROC" | bc 2>/dev/null || echo 0)
      if [ "$GPU_BUSY" -gt 15 ] || [ "''${LOAD_PCT%.*}" -gt 35 ] || pgrep -i -x "steam|gamescope|lutris|heroic|java|obs|ffmpeg|nix-daemon|hyprlock" >/dev/null 2>&1; then
        exit 0
      fi

      NOTIF_JSON=$(${pkgs.swaynotificationcenter}/bin/swaync-client -s 2>/dev/null || echo '[]')
      NOTIF_COUNT=$(echo "$NOTIF_JSON" | ${pkgs.jq}/bin/jq 'length' 2>/dev/null || echo "0")

      if [ "$NOTIF_COUNT" -eq 0 ]; then
        if [[ "''${1:-}" == "--toast" ]]; then
          exit 0  # Silent exit for timer — no notifications to digest
        else
          echo "No notifications to summarize."
        fi
        exit 0
      fi

      NOTIF_TEXT=$(echo "$NOTIF_JSON" | ${pkgs.jq}/bin/jq -r '.[-30:][] | "[\(.data."app-name".data // "Unknown")] \(.data.summary.data // "") - \(.data.body.data // "")"' 2>/dev/null || echo "$NOTIF_JSON" | head -c 3000)

      PROMPT="Summarize these desktop notifications into a brief, organized digest. Group by application. Highlight anything urgent. Be concise.

      Notifications:
      $NOTIF_TEXT"

      PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg m "$MODEL" --arg p "$PROMPT" '{model: $m, prompt: $p, stream: false}')
      RAW_RES=$(${pkgs.curl}/bin/curl -s "$OLLAMA_URL" -d "$PAYLOAD" 2>/dev/null)
      RESPONSE=$(echo "$RAW_RES" | ${pkgs.jq}/bin/jq -r '.response // "Failed to generate digest."')

      if [[ "''${1:-}" == "--toast" ]]; then
        ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:ai-digest \
          "󰂚 AI Digest ($NOTIF_COUNT notifications)" "$RESPONSE" -i dialog-information
        command -v thinkdot >/dev/null 2>&1 && thinkdot burst 3 || true
      else
        echo ""
        echo "󰂚 AI Notification Digest ($NOTIF_COUNT notifications)"
        echo "================================================"
        echo "$RESPONSE"
      fi
    '';
  };

  # ─── Git Prepare-Commit-Msg Hook (E4B, bug-fixed) ─────────────────────

  xdg.configFile."ai/git-prepare-commit-msg.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      COMMIT_MSG_FILE="$1"
      COMMIT_SOURCE="$2"
      # Only for regular commits (not merge, squash, amend)
      if [ -n "$COMMIT_SOURCE" ]; then exit 0; fi

      OLLAMA_URL="http://127.0.0.1:11434/api/generate"
      PREF_MODEL="hf.co/huihui-ai/Huihui-gemma-4-E4B-it-qat-q4_0-unquantized-abliterated-GGUF"
      DIFF=$(git diff --cached --stat && echo "---" && git diff --cached | head -c 4000)
      if [ -z "$DIFF" ]; then exit 0; fi

      TAGS=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/tags 2>/dev/null || echo '{}')
      TARGET=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r --arg pref "$PREF_MODEL" '.models[]? | select(.name != "nomic-embed-text:latest") | .name | select(contains($pref))' | head -n 1)
      FIRST=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r '.models[]? | select(.name != "nomic-embed-text:latest") | .name' | head -n 1)
      MODEL="''${TARGET:-''${FIRST:-$PREF_MODEL}}"

      PROMPT="Generate a single concise Conventional Commit message for this git diff. Format: type(scope): description. Types: feat, fix, refactor, docs, style, test, chore. Output ONLY the commit message, no markdown fences.

      $DIFF"

      PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg m "$MODEL" --arg p "$PROMPT" '{model: $m, prompt: $p, stream: false}')
      RAW_RES=$(${pkgs.curl}/bin/curl -s "$OLLAMA_URL" -d "$PAYLOAD" 2>/dev/null)
      AI_MSG=$(echo "$RAW_RES" | ${pkgs.jq}/bin/jq -r '.response // empty' | sed 's/^```//;s/```$//' | head -n 3 | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

      if [ -n "$AI_MSG" ] && [ "$AI_MSG" != "null" ]; then
        ORIGINAL=$(cat "$COMMIT_MSG_FILE")
        echo "$AI_MSG" > "$COMMIT_MSG_FILE"
        echo "" >> "$COMMIT_MSG_FILE"
        echo "# AI-suggested commit message (E4B). Edit freely." >> "$COMMIT_MSG_FILE"
        echo "$ORIGINAL" | sed 's/^/# /' >> "$COMMIT_MSG_FILE"
      fi
    '';
  };

  # ─── Multi-Modal Vector Indexer & Hybrid File Search ───────────────────

  xdg.configFile."ai/vector_indexer.py" = {
    executable = true;
    text = builtins.readFile ./ai/vector_indexer.py;
  };

  # ─── Spotlight Search (with AI fallback) ───────────────────────────────

  xdg.configFile."hypr/scripts/spotlight.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Spotlight-style Unified Search: Apps, files, AI prompt, web search
      # AI fallback: when no app/file/dir matches, query E2B before web search

      cd "$HOME" || exit 1

      APP_DIRS=(
        "/run/current-system/sw/share/applications"
        "/etc/profiles/per-user/justkowal/share/applications"
        "/home/justkowal/.nix-profile/share/applications"
        "/home/justkowal/.local/share/applications"
        "/var/lib/flatpak/exports/share/applications"
        "/home/justkowal/.local/share/flatpak/exports/share/applications"
      )

      # 1. Collect installed desktop applications
      APP_LIST=$(${pkgs.findutils}/bin/find "''${APP_DIRS[@]}" -name "*.desktop" 2>/dev/null | while read -r file; do
        if ${pkgs.gnugrep}/bin/grep -qE "^(NoDisplay|Hidden)=true" "$file"; then continue; fi
        name=$(${pkgs.gnugrep}/bin/grep -m 1 "^Name=" "$file" | ${pkgs.coreutils}/bin/cut -d= -f2-)
        [ -n "$name" ] && echo "[App] $name"
      done | ${pkgs.coreutils}/bin/sort -u)

      # 2. Collect user files and directories (depth 3)
      FILES_AND_DIRS=$(${pkgs.fd}/bin/fd --max-depth 3 --hidden --exclude .git --exclude .cache . /home/justkowal 2>/dev/null | while read -r path; do
        if [ -d "$path" ]; then echo "[Dir] $path"
        elif [ -f "$path" ]; then echo "[File] $path"
        fi
      done)

      CHOICES=$(printf "%s\n%s" "$APP_LIST" "$FILES_AND_DIRS")
      INPUT=$(echo "$CHOICES" | rofi -dmenu -i -p "Spotlight" -mesg "Prefixes:  v: vector search  |  ai: / ? local AI  |  g: / web: web search" -font "Outfit 12" -theme-str 'window {width: 750px;}')
      [ -z "$INPUT" ] && exit 0

      CLEAN_INPUT=$(echo "$INPUT" | ${pkgs.gnused}/bin/sed -E 's/^\[(App|Dir|File)\]\s*//')

      # Check if it's an existing file or directory
      if [ -e "$CLEAN_INPUT" ]; then
        ${pkgs.xdg-utils}/bin/xdg-open "$CLEAN_INPUT" &
        exit 0
      fi

      # Check if it matches a desktop application
      DESKTOP_FILE=$(${pkgs.findutils}/bin/find "''${APP_DIRS[@]}" -name "*.desktop" 2>/dev/null | while read -r file; do
        if ${pkgs.gnugrep}/bin/grep -qE "^(NoDisplay|Hidden)=true" "$file"; then continue; fi
        name=$(${pkgs.gnugrep}/bin/grep -m 1 "^Name=" "$file" | ${pkgs.coreutils}/bin/cut -d= -f2-)
        base=$(${pkgs.coreutils}/bin/basename "$file" .desktop)
        name_lower=$(echo "$name" | ${pkgs.coreutils}/bin/tr '[:upper:]' '[:lower:]')
        clean_lower=$(echo "$CLEAN_INPUT" | ${pkgs.coreutils}/bin/tr '[:upper:]' '[:lower:]')
        base_lower=$(echo "$base" | ${pkgs.coreutils}/bin/tr '[:upper:]' '[:lower:]')
        if [ "$name_lower" = "$clean_lower" ] || [ "$base_lower" = "$clean_lower" ] || [ "$name" = "$INPUT" ]; then
          echo "$file"
          break
        fi
      done | ${pkgs.coreutils}/bin/head -n 1)

      if [ -n "$DESKTOP_FILE" ]; then
        is_terminal=$(${pkgs.gnugrep}/bin/grep -iE "^Terminal=(true|1)" "$DESKTOP_FILE")
        exec_raw=$(${pkgs.gnugrep}/bin/grep -m 1 "^Exec=" "$DESKTOP_FILE" | ${pkgs.coreutils}/bin/cut -d= -f2-)
        exec_cmd=$(echo "$exec_raw" | ${pkgs.gnused}/bin/sed -E 's/%[a-zA-Z0-9%]//g')
        desktop_id=$(${pkgs.coreutils}/bin/basename "$DESKTOP_FILE")
        if [ -n "$is_terminal" ]; then
          ${pkgs.kitty}/bin/kitty -e sh -c "$exec_cmd" &
        else
          ${pkgs.gtk3}/bin/gtk-launch "$desktop_id" 2>/dev/null || (eval "$exec_cmd" &)
        fi
        exit 0
      fi

      # Vector search prefix (v:, vec:, sem:)
      if [[ "$INPUT" =~ ^(v:|vec:|sem:).* ]]; then
        PROMPT=$(echo "$INPUT" | ${pkgs.gnused}/bin/sed -E 's/^(v:|vec:|sem:)\s*//')
        MATCHED_FILES=$(${pkgs.fd}/bin/fd -i --hidden --exclude .git "$PROMPT" /home/justkowal | ${pkgs.coreutils}/bin/head -n 10)
        if [ -n "$MATCHED_FILES" ]; then
          SELECTED_FILE=$(echo "$MATCHED_FILES" | rofi -dmenu -i -p "Vector Matches ($PROMPT)" -font "Outfit 11" -theme-str 'window {width: 800px;}')
          [ -n "$SELECTED_FILE" ] && [ -e "$SELECTED_FILE" ] && ${pkgs.xdg-utils}/bin/xdg-open "$SELECTED_FILE" &
        else
          ${pkgs.libnotify}/bin/notify-send "Spotlight Vector Search" "No matches found for: $PROMPT"
        fi
        exit 0
      fi

      # AI Query Handler with Model Tiers (ai: / ? -> E2B, ai-task: -> E4B, ai-papa: -> 12B)
      if [[ "$INPUT" =~ ^(\?|ai:|ai-task:|ai-papa:).* ]]; then
        if [[ "$INPUT" =~ ^ai-papa:.* ]]; then
          CLEAN_PROMPT=$(echo "$INPUT" | ${pkgs.gnused}/bin/sed -E 's/^ai-papa:\s*//')
          PREF_MODEL="hf.co/huihui-ai/Huihui-gemma-4-12B-it-qat-q4_0-unquantized-abliterated-GGUF"
          MODEL_LABEL="12B Big Papa"
        elif [[ "$INPUT" =~ ^ai-task:.* ]]; then
          CLEAN_PROMPT=$(echo "$INPUT" | ${pkgs.gnused}/bin/sed -E 's/^ai-task:\s*//')
          PREF_MODEL="hf.co/huihui-ai/Huihui-gemma-4-E4B-it-qat-q4_0-unquantized-abliterated-GGUF"
          MODEL_LABEL="E4B Task Model"
        else
          CLEAN_PROMPT=$(echo "$INPUT" | ${pkgs.gnused}/bin/sed -E 's/^(\?|ai:)\s*//')
          PREF_MODEL="hf.co/huihui-ai/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-GGUF"
          MODEL_LABEL="E2B Instant"
        fi

        TAGS=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/tags)
        MATCHED_MODEL=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r --arg pref "$PREF_MODEL" '.models[]? | select(.name != "nomic-embed-text:latest") | .name | select(contains($pref) or startswith($pref))' | ${pkgs.coreutils}/bin/head -n 1)
        FIRST_AVAIL=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r '.models[]? | select(.name != "nomic-embed-text:latest") | .name' | ${pkgs.coreutils}/bin/head -n 1)
        TARGET_MODEL="''${MATCHED_MODEL:-''${FIRST_AVAIL:-$PREF_MODEL}}"

        CONVERSATION="System: You are a local AI assistant. Answer directly and concisely.\n"
        CURRENT_PROMPT="$CLEAN_PROMPT"

        while true; do
          CONVERSATION="$CONVERSATION User: $CURRENT_PROMPT\nAssistant:"
          PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg m "$TARGET_MODEL" --arg p "$CONVERSATION" '{model: $m, prompt: $p, stream: false}')
          ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:spotlight-ai "Spotlight AI ($MODEL_LABEL)" "Thinking..." -i dialog-information
          RAW_RES=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/generate -d "$PAYLOAD")
          RESPONSE=$(echo "$RAW_RES" | ${pkgs.jq}/bin/jq -r '.response // empty')
          ERR_MSG=$(echo "$RAW_RES" | ${pkgs.jq}/bin/jq -r '.error // empty')

          if [ -z "$RESPONSE" ] || [ "$RESPONSE" = "null" ]; then
            if [ -n "$ERR_MSG" ]; then
              ${pkgs.libnotify}/bin/notify-send "Spotlight AI Error" "$ERR_MSG" -u critical
            else
              ${pkgs.libnotify}/bin/notify-send "Spotlight AI Error" "Failed to get response." -u critical
            fi
            exit 1
          fi

          CONVERSATION="$CONVERSATION $RESPONSE\n"
          CHAR_COUNT=$(echo -n "$RESPONSE" | ${pkgs.coreutils}/bin/wc -c)
          PANGO_RESP=$(${pkgs.python3}/bin/python3 %h/.config/ai/md_to_pango.py "$RESPONSE")
          ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:spotlight-ai "Spotlight AI ($MODEL_LABEL)" "$PANGO_RESP" -i dialog-information
          echo "$RESPONSE" | ${pkgs.wl-clipboard}/bin/wl-copy

          if [ "$CHAR_COUNT" -gt 200 ]; then
            TMP_RESP="/tmp/spotlight_ai_res_$$.md"
            echo -e "# Spotlight AI Response ($MODEL_LABEL)\n\n$RESPONSE" > "$TMP_RESP"
            ${pkgs.kitty}/bin/kitty --class scratchpad -e ${pkgs.glow}/bin/glow "$TMP_RESP" &
          fi

          SUMMARY_TEXT=$(echo "$RESPONSE" | ${pkgs.coreutils}/bin/head -n 2 | ${pkgs.coreutils}/bin/tr '\n' ' ')
          CHOICE=$(echo -e "󰈙 Response Summary: $SUMMARY_TEXT\n󰭻 Continue Chat\n󰆏 Copy Response\n󰖟 Open in Open-WebUI\n󰅖 Close" | rofi -dmenu -i -p "Spotlight AI ($MODEL_LABEL)" -mesg "$RESPONSE" -font "Outfit 11" -theme-str 'window {width: 850px;} message {border: 2px; border-radius: 12px; padding: 12px; margin: 0px 0px 10px 0px;} textbox {wrap: true;} listview {lines: 5;} element {padding: 8px;}')

          if [ -z "$CHOICE" ] || [[ "$CHOICE" =~ "Close" ]]; then exit 0
          elif [[ "$CHOICE" =~ "Copy Response" ]]; then
            echo "$RESPONSE" | ${pkgs.wl-clipboard}/bin/wl-copy
            ${pkgs.libnotify}/bin/notify-send "Spotlight AI" "Response copied!"
            exit 0
          elif [[ "$CHOICE" =~ "Open-WebUI" ]]; then
            ENCODED_PROMPT=$(echo -n "$CURRENT_PROMPT" | ${pkgs.jq}/bin/jq -sRr @uri)
            ( ${pkgs.xdg-utils}/bin/xdg-open "http://127.0.0.1:11111/?q=$ENCODED_PROMPT" ) >/dev/null 2>&1 & disown
            exit 0
          else
            TYPED_REPLY=$(echo "$CHOICE" | ${pkgs.gnused}/bin/sed -E 's/^\s*([󰈙󰭻󰆏󰖟󰅖]).*\s*//')
            [ -z "$TYPED_REPLY" ] && TYPED_REPLY=$(rofi -dmenu -i -p "Your Reply ($MODEL_LABEL)" -font "Outfit 12" -theme-str 'window {width: 650px;}')
            [ -z "$TYPED_REPLY" ] && exit 0
            CURRENT_PROMPT="$TYPED_REPLY"
          fi
        done
        exit 0
      fi

      # Web Search prefix (g: or web:)
      if [[ "$INPUT" =~ ^g:.* ]] || [[ "$INPUT" =~ ^web:.* ]]; then
        SEARCH_QUERY=$(echo "$INPUT" | ${pkgs.gnused}/bin/sed -E 's/^(g:|web:)\s*//')
        ENCODED=$(${pkgs.jq}/bin/jq -rr --arg q "$SEARCH_QUERY" '$q | @uri')
        ${pkgs.xdg-utils}/bin/xdg-open "http://127.0.0.1:8888/search?q=$ENCODED"
        exit 0
      fi

      # Deep File & Directory Search fallback (fd)
      MATCHED_FILE=$(${pkgs.fd}/bin/fd -i --hidden --exclude .git "$CLEAN_INPUT" /home/justkowal | ${pkgs.coreutils}/bin/head -n 1)
      if [ -n "$MATCHED_FILE" ] && [ -e "$MATCHED_FILE" ]; then
        ${pkgs.xdg-utils}/bin/xdg-open "$MATCHED_FILE" &
        exit 0
      fi

      # Fallback: No matching application or file found
      # Apple HIG Agency & Transparency: Provide explicit choice rather than silent AI/web fallback
      ACTION=$(echo -e "󰖟 Search Web for \"$CLEAN_INPUT\"\n󰧑 Ask Local AI: \"$CLEAN_INPUT\"\n󰅖 Dismiss" | rofi -dmenu -i -p "No Match Found" -mesg "Query \"$CLEAN_INPUT\" did not match any applications or files." -font "Outfit 11" -theme-str 'window {width: 650px;} listview {lines: 3;} element {padding: 8px 12px;}')

      case "$ACTION" in
        *"Search Web"*)
          ENCODED=$(${pkgs.jq}/bin/jq -rr --arg q "$CLEAN_INPUT" '$q | @uri')
          ${pkgs.xdg-utils}/bin/xdg-open "http://127.0.0.1:8888/search?q=$ENCODED"
          ;;
        *"Ask Local AI"*)
          AI_FALLBACK_MODEL="hf.co/huihui-ai/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-GGUF"
          TAGS=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/tags 2>/dev/null || echo '{}')
          FB_MODEL=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r --arg pref "$AI_FALLBACK_MODEL" '.models[]? | .name | select(contains($pref))' | head -n 1)
          FB_FIRST=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r '.models[]? | select(.name != "nomic-embed-text:latest") | .name' | head -n 1)
          FB_TARGET="''${FB_MODEL:-''${FB_FIRST:-$AI_FALLBACK_MODEL}}"

          FB_PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg m "$FB_TARGET" --arg p "Answer directly and concisely: $CLEAN_INPUT" '{model: $m, prompt: $p, stream: false}')
          FB_RES=$(${pkgs.curl}/bin/curl -s --max-time 10 http://127.0.0.1:11434/api/generate -d "$FB_PAYLOAD" 2>/dev/null)
          FB_ANSWER=$(echo "$FB_RES" | ${pkgs.jq}/bin/jq -r '.response // empty' 2>/dev/null)

          if [ -n "$FB_ANSWER" ] && [ "$FB_ANSWER" != "null" ]; then
            echo "$FB_ANSWER" | ${pkgs.wl-clipboard}/bin/wl-copy
            ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:spotlight-ai "󰧑 Spotlight AI" "$FB_ANSWER" -i dialog-information
          fi
          ;;
        *)
          exit 0
          ;;
      esac
    '';
  };

  # NEW AMBIENT AI INTEGRATIONS

  # ─── 1. Smart Context-Aware Clipboard Daemon ───────────────────────────

  xdg.configFile."ai/clipboard_context.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Smart Context-Aware Clipboard — Detects content type, offers AI actions
      # via SwayNC desktop notifications with action buttons.

      OLLAMA_URL="http://127.0.0.1:11434/api/generate"
      E2B_MODEL="hf.co/huihui-ai/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-GGUF"
      LAST_HASH=""
      COOLDOWN_SECS=3
      LAST_ACTION_TIME=0

      resolve_model() {
        local TAGS=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/tags 2>/dev/null || echo '{}')
        local MATCHED=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r --arg pref "$E2B_MODEL" '.models[]? | select(.name != "nomic-embed-text:latest") | .name | select(contains($pref))' | head -n 1)
        local FIRST=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r '.models[]? | select(.name != "nomic-embed-text:latest") | .name' | head -n 1)
        echo "''${MATCHED:-''${FIRST:-$E2B_MODEL}}"
      }

      classify_content() {
        local text="$1"
        local len=''${#text}

        # Too short — ignore
        [ "$len" -lt 20 ] && echo "ignore" && return

        # URL pattern
        if echo "$text" | ${pkgs.gnugrep}/bin/grep -qE '^https?://'; then
          echo "url"; return
        fi

        # Email pattern
        if echo "$text" | ${pkgs.gnugrep}/bin/grep -qE '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
          echo "email"; return
        fi

        # Error / stacktrace pattern
        if echo "$text" | ${pkgs.gnugrep}/bin/grep -qiE '(error|exception|traceback|panic|segfault|SIGSEGV|failed|fatal)'; then
          echo "error"; return
        fi

        # Code pattern (contains braces, semicolons, def/fn/func/class, import)
        if echo "$text" | ${pkgs.gnugrep}/bin/grep -qE '(\{|\}|;$|^(def |fn |func |class |import |from |#include|const |let |var ))'; then
          echo "code"; return
        fi

        # Long prose (>100 chars, mostly alphabetic)
        if [ "$len" -gt 100 ]; then
          echo "prose"; return
        fi

        echo "ignore"
      }

      do_ai_action() {
        local action="$1"
        local text="$2"
        local MODEL=$(resolve_model)
        local PROMPT=""

        case "$action" in
          format_code)
            PROMPT="Reformat and clean up this code. Output ONLY the formatted code, no explanations:\n\n$text" ;;
          explain_code)
            PROMPT="Explain this code concisely in 2-3 sentences:\n\n$text" ;;
          summarize_url)
            PROMPT="Given this URL: $text — What is this page likely about? Answer in 1 sentence." ;;
          summarize_prose)
            PROMPT="Summarize this text concisely in 1-2 sentences:\n\n$text" ;;
          translate_prose)
            PROMPT="Translate this text to English (or if already English, to Polish). Output ONLY the translation:\n\n$text" ;;
          diagnose_error)
            PROMPT="Diagnose this error/log concisely. What went wrong and how to fix it? 2-3 sentences max:\n\n$text" ;;
          *) return ;;
        esac

        ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:clip-ai "󰧑 Clipboard AI" "Processing..." -i dialog-information

        local PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg m "$MODEL" --arg p "$PROMPT" '{model: $m, prompt: $p, stream: false}')
        local RAW_RES=$(${pkgs.curl}/bin/curl -s "$OLLAMA_URL" -d "$PAYLOAD" 2>/dev/null)
        local RESPONSE=$(echo "$RAW_RES" | ${pkgs.jq}/bin/jq -r '.response // empty')

        if [ -n "$RESPONSE" ] && [ "$RESPONSE" != "null" ]; then
          echo "$RESPONSE" | ${pkgs.wl-clipboard}/bin/wl-copy
          ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:clip-ai "󰄬 Clipboard AI" "$RESPONSE" -i dialog-information
        fi
      }

      offer_actions() {
        local content_type="$1"
        local text="$2"
        local preview=$(echo "$text" | head -c 80 | tr '\n' ' ')

        case "$content_type" in
          code)
            CHOICE=$(echo -e "󰉦 Format Code\n󰌵 Explain Code\n󰅖 Dismiss" | ${pkgs.rofi}/bin/rofi -dmenu -i -p "󰅩 Code Detected" -mesg "$preview" -font "Outfit 11" -theme-str 'window {width: 500px;} listview {lines: 3;}')
            if [[ "$CHOICE" =~ "Format" ]]; then do_ai_action "format_code" "$text"
            elif [[ "$CHOICE" =~ "Explain" ]]; then do_ai_action "explain_code" "$text"
            fi ;;
          url)
            CHOICE=$(echo -e "󰈙 Summarize Page\n󰅖 Dismiss" | ${pkgs.rofi}/bin/rofi -dmenu -i -p "󰌹 URL Detected" -mesg "$preview" -font "Outfit 11" -theme-str 'window {width: 500px;} listview {lines: 2;}')
            [[ "$CHOICE" =~ "Summarize" ]] && do_ai_action "summarize_url" "$text"
            ;;
          error)
            CHOICE=$(echo -e "󰡏 Diagnose Error\n󰅖 Dismiss" | ${pkgs.rofi}/bin/rofi -dmenu -i -p "󰅚 Error Detected" -mesg "$preview" -font "Outfit 11" -theme-str 'window {width: 500px;} listview {lines: 2;}')
            [[ "$CHOICE" =~ "Diagnose" ]] && do_ai_action "diagnose_error" "$text"
            ;;
          prose)
            CHOICE=$(echo -e "󰈙 Summarize\n󰖟 Translate\n󰅖 Dismiss" | ${pkgs.rofi}/bin/rofi -dmenu -i -p "󰈙 Text Detected" -mesg "$preview" -font "Outfit 11" -theme-str 'window {width: 500px;} listview {lines: 3;}')
            if [[ "$CHOICE" =~ "Summarize" ]]; then do_ai_action "summarize_prose" "$text"
            elif [[ "$CHOICE" =~ "Translate" ]]; then do_ai_action "translate_prose" "$text"
            fi ;;
        esac
      }

      # Main watch loop
      echo "Smart Clipboard Context daemon running..."
      while true; do
        CLIP_TEXT=$(${pkgs.wl-clipboard}/bin/wl-paste -n 2>/dev/null || true)
        if [ -n "$CLIP_TEXT" ]; then
          HASH=$(echo -n "$CLIP_TEXT" | md5sum | cut -d' ' -f1)
          NOW=$(date +%s)
          if [ "$HASH" != "$LAST_HASH" ] && [ $((NOW - LAST_ACTION_TIME)) -gt $COOLDOWN_SECS ]; then
            LAST_HASH="$HASH"
            CONTENT_TYPE=$(classify_content "$CLIP_TEXT")
            if [ "$CONTENT_TYPE" != "ignore" ]; then
              LAST_ACTION_TIME=$NOW
              offer_actions "$CONTENT_TYPE" "$CLIP_TEXT"
            fi
          fi
        fi
        sleep 2
      done
    '';
  };

  # ─── 2. Proactive System Health Advisor ────────────────────────────────

  xdg.configFile."ai/health_advisor.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Proactive System Health Advisor — Checks system metrics, sends AI-authored
      # alerts ONLY when something is genuinely anomalous. Silent otherwise.

      OLLAMA_URL="http://127.0.0.1:11434/api/generate"
      E2B_MODEL="hf.co/huihui-ai/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-GGUF"

      resolve_model() {
        local TAGS=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/tags 2>/dev/null || echo '{}')
        local MATCHED=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r --arg pref "$E2B_MODEL" '.models[]? | .name | select(contains($pref))' | head -n 1)
        local FIRST=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r '.models[]? | select(.name != "nomic-embed-text:latest") | .name' | head -n 1)
        echo "''${MATCHED:-''${FIRST:-$E2B_MODEL}}"
      }

      # Gather metrics
      RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
      RAM_USED=$(free -m | awk '/Mem:/ {print $3}')
      RAM_PCT=$((RAM_USED * 100 / RAM_TOTAL))

      DISK_PCT=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')

      CPU_TEMP=0
      CPU_TEMP_FILE=$(grep -l "k10temp" /sys/class/hwmon/hwmon*/name 2>/dev/null | head -n 1)
      if [ -n "$CPU_TEMP_FILE" ]; then
        CPU_TEMP_DIR=$(dirname "$CPU_TEMP_FILE")
        [ -f "$CPU_TEMP_DIR/temp1_input" ] && CPU_TEMP=$(( $(cat "$CPU_TEMP_DIR/temp1_input") / 1000 ))
      fi

      GPU_TEMP=0
      GPU_TEMP_FILE=$(find /sys/class/drm/card1/device/hwmon/ -name "temp1_input" 2>/dev/null | head -n 1)
      [ -f "$GPU_TEMP_FILE" ] && GPU_TEMP=$(( $(cat "$GPU_TEMP_FILE") / 1000 ))

      NPROC=$(nproc)
      LOAD_1M=$(uptime | awk -F'load average:' '{print $2}' | awk -F, '{print $1}' | tr -d ' ')
      LOAD_THRESHOLD=$(echo "$NPROC * 2" | bc)
      LOAD_HIGH=$(echo "$LOAD_1M > $LOAD_THRESHOLD" | bc 2>/dev/null || echo 0)

      # Detect gaming & heavy workload processes (Steam, Gamescope, Lutris, Heroic, Minecraft/Java, OBS, FFmpeg, Nix build, etc.)
      if pgrep -i -x "steam|gamescope|lutris|heroic|java|obs|ffmpeg|nix-daemon|hyprlock" >/dev/null 2>&1 || pgrep -f "minecraft|PrismLauncher" >/dev/null 2>&1; then
        # Heavy workload / game active — suppress resource anomaly alerts
        exit 0
      fi

      # Check thresholds
      ANOMALIES=""
      [ "$RAM_PCT" -gt 85 ] && ANOMALIES="$ANOMALIES RAM at ''${RAM_PCT}% (''${RAM_USED}MB/''${RAM_TOTAL}MB)."
      [ "$DISK_PCT" -gt 90 ] && ANOMALIES="$ANOMALIES Root disk at ''${DISK_PCT}%."
      [ "$CPU_TEMP" -gt 85 ] && ANOMALIES="$ANOMALIES CPU temp ''${CPU_TEMP}°C."
      [ "$GPU_TEMP" -gt 90 ] && ANOMALIES="$ANOMALIES GPU temp ''${GPU_TEMP}°C."
      [ "$LOAD_HIGH" = "1" ] && ANOMALIES="$ANOMALIES System load ''${LOAD_1M} (threshold: ''${LOAD_THRESHOLD})."

      # Exit silently if nothing anomalous
      if [ -z "$ANOMALIES" ]; then
        exit 0
      fi

      # Gather context for AI
      TOP_RAM=$(ps aux --sort=-%mem | head -n 6 | awk 'NR>1 {printf "  %s (%.1f%% RAM, %.1f%% CPU)\n", $11, $4, $3}')
      TOP_CPU=$(ps aux --sort=-%cpu | head -n 6 | awk 'NR>1 {printf "  %s (%.1f%% CPU, %.1f%% RAM)\n", $11, $3, $4}')
      DISK_INFO=$(df -h / | awk 'NR==2 {print "Used: " $3 "/" $2 " (" $5 ")"}')

      CONTEXT="ANOMALIES:$ANOMALIES
      Top RAM consumers:
      $TOP_RAM
      Top CPU consumers:
      $TOP_CPU
      Disk: $DISK_INFO"

      MODEL=$(resolve_model)
      PROMPT="You are a system health advisor. Given these anomalies, write ONE brief notification sentence explaining what's unusual and a short actionable suggestion. Be specific (mention process names if relevant).

      $CONTEXT"

      PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg m "$MODEL" --arg p "$PROMPT" '{model: $m, prompt: $p, stream: false}')
      RAW_RES=$(${pkgs.curl}/bin/curl -s --max-time 10 "$OLLAMA_URL" -d "$PAYLOAD" 2>/dev/null)
      RESPONSE=$(echo "$RAW_RES" | ${pkgs.jq}/bin/jq -r '.response // empty')

      if [ -n "$RESPONSE" ] && [ "$RESPONSE" != "null" ]; then
        PANGO_RES=$(${pkgs.python3}/bin/python3 %h/.config/ai/md_to_pango.py "$RESPONSE")
        ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:health-ai \
          "󰓅 System Health" "$PANGO_RES" -i dialog-warning
      fi
    '';
  };

  # ─── 3. Smart File Auto-Organizer Daemon (inotifywait) ─────────────────

  xdg.configFile."ai/file_organizer_daemon.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Smart File Auto-Organizer — Watches ~/Downloads for new files and
      # silently classifies + moves them to the appropriate directory.

      WATCH_DIR="$HOME/Downloads"
      LOG_FILE="$HOME/.local/state/ai-organize.log"
      OLLAMA_URL="http://127.0.0.1:11434/api/generate"
      E4B_MODEL="hf.co/huihui-ai/Huihui-gemma-4-E4B-it-qat-q4_0-unquantized-abliterated-GGUF"
      SETTLE_SECS=5
      MAX_FILE_MB=100

      PROTECTED_KEYWORDS="cyberpunk repack dodi fitgirl steam game games wine lutris heroic"

      mkdir -p "$(dirname "$LOG_FILE")"
      mkdir -p "$WATCH_DIR"

      resolve_model() {
        local TAGS=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/tags 2>/dev/null || echo '{}')
        local MATCHED=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r --arg pref "$E4B_MODEL" '.models[]? | .name | select(contains($pref))' | head -n 1)
        local FIRST=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r '.models[]? | select(.name != "nomic-embed-text:latest") | .name' | head -n 1)
        echo "''${MATCHED:-''${FIRST:-$E4B_MODEL}}"
      }

      classify_file() {
        local filename="$1"
        local ext=$(echo "$filename" | ${pkgs.gawk}/bin/awk -F. '{print tolower($NF)}')

        # Fast-path: extension-based classification
        case "$ext" in
          pdf) echo "Documents/PDFs"; return ;;
          md|txt|org) echo "Documents/Notes"; return ;;
          docx|doc|odt|rtf) echo "Documents/Docs"; return ;;
          png|jpg|jpeg|webp|svg|gif|bmp)
            local fn_lower=$(echo "$filename" | tr '[:upper:]' '[:lower:]')
            if [[ "$fn_lower" =~ (screen|snap|shot) ]]; then echo "Pictures/Screenshots"; return; fi
            if [[ "$fn_lower" =~ (wall|bg_|desktop) ]]; then echo "Pictures/Wallpapers"; return; fi
            echo "Pictures"; return ;;
          zip|tar|gz|xz|7z|rar|zst) echo "Downloads/Archives"; return ;;
          appimage|deb|rpm|iso|img) echo "Downloads/Installers"; return ;;
          fcstd|kicad_pcb|kicad_sch|stl|step|stp|3mf) echo "CAD"; return ;;
          mp4|mkv|webm|avi|mov) echo "Media/Videos"; return ;;
          mp3|flac|wav|ogg|m4a) echo "Media/Audio"; return ;;
        esac

        # AI classification for ambiguous files
        local MODEL=$(resolve_model)
        local PROMPT="Classify file '$filename' into ONE category: Documents/PDFs, Documents/Notes, Documents/Docs, Pictures, Downloads/Archives, Downloads/Installers, CAD, Media/Videos, Media/Audio, Projects/Code, Downloads/Miscellaneous. Return ONLY JSON: {\"category\": \"chosen_category\"}"
        local PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg m "$MODEL" --arg p "$PROMPT" '{model: $m, prompt: $p, format: "json", stream: false}')
        local RAW=$(${pkgs.curl}/bin/curl -s --max-time 8 "$OLLAMA_URL" -d "$PAYLOAD" 2>/dev/null)
        local CATEGORY=$(echo "$RAW" | ${pkgs.jq}/bin/jq -r '.response // "{}"' 2>/dev/null | ${pkgs.jq}/bin/jq -r '.category // empty' 2>/dev/null)

        if [ -n "$CATEGORY" ] && [[ "$CATEGORY" != *".."* ]] && [[ "$CATEGORY" != "."* ]]; then
          echo "$CATEGORY"
        else
          echo "Downloads/Miscellaneous"
        fi
      }

      is_protected() {
        local fn_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
        for kw in $PROTECTED_KEYWORDS; do
          if [[ "$fn_lower" == *"$kw"* ]]; then return 0; fi
        done
        return 1
      }

      process_file() {
        local filepath="$1"
        local filename=$(basename "$filepath")

        # Skip dotfiles
        [[ "$filename" == .* ]] && return

        # Wait for file to settle (downloads in progress)
        sleep $SETTLE_SECS

        # Skip if file disappeared or is still being written
        [ ! -f "$filepath" ] && return

        # Skip large files
        local size_mb=$(( $(stat -c%s "$filepath" 2>/dev/null || echo 0) / 1048576 ))
        [ "$size_mb" -gt "$MAX_FILE_MB" ] && return

        # Skip protected
        if is_protected "$filename"; then return; fi

        local category=$(classify_file "$filename")
        local dest_dir="$HOME/$category"
        local dest_path="$dest_dir/$filename"

        # Don't move to same location
        [ "$filepath" = "$dest_path" ] && return

        mkdir -p "$dest_dir"
        mv "$filepath" "$dest_path" 2>/dev/null || return

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] MOVED: $filepath -> $dest_path" >> "$LOG_FILE"
        ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:file-org \
          "󰉋 Auto-Organized" "$filename → $category/" -i folder
      }

      echo "File Auto-Organizer daemon watching $WATCH_DIR..."
      ${pkgs.inotify-tools}/bin/inotifywait -m -e close_write,moved_to --format '%w%f' "$WATCH_DIR" 2>/dev/null | while read filepath; do
        process_file "$filepath" &
      done
    '';
  };

  # ─── 4. Contextual Waybar AI Widget ────────────────────────────────────

  xdg.configFile."waybar/scripts/ai_ambient.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Contextual AI Waybar Widget — Generates a rotating one-liner every 5 minutes
      # based on system context. Caches responses to avoid redundant LLM calls.

      CACHE_FILE="/tmp/waybar_ai_ambient_cache"
      CACHE_TTL=290  # slightly under 5min to avoid stale display
      OLLAMA_URL="http://127.0.0.1:11434/api/generate"
      E2B_MODEL="hf.co/huihui-ai/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-GGUF"

      # Check cache
      if [ -f "$CACHE_FILE" ]; then
        CACHE_AGE=$(( $(date +%s) - $(stat -c%Y "$CACHE_FILE") ))
        if [ "$CACHE_AGE" -lt "$CACHE_TTL" ]; then
          cat "$CACHE_FILE"
          exit 0
        fi
      fi

      # Resolve model
      TAGS=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/tags 2>/dev/null || echo '{}')
      MATCHED=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r --arg pref "$E2B_MODEL" '.models[]? | .name | select(contains($pref))' | head -n 1)
      FIRST=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r '.models[]? | select(.name != "nomic-embed-text:latest") | .name' | head -n 1)
      MODEL="''${MATCHED:-''${FIRST:-$E2B_MODEL}}"

      # Gather context
      HOUR=$(date +%H)
      UPTIME=$(${pkgs.procps}/bin/uptime -p 2>/dev/null | sed 's/up //' || echo "active")
      RAM_PCT=$(free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
      DISK_PCT=$(df / | awk 'NR==2 {print $5}')
      WORKSPACES=$(${pkgs.hyprland}/bin/hyprctl workspaces -j 2>/dev/null | ${pkgs.jq}/bin/jq 'length' 2>/dev/null || echo "?")
      LAST_GIT=$(cd /etc/nixos && git log --oneline -1 --format="%ar" 2>/dev/null || echo "unknown")

      # Rotate prompt category based on minute
      MINUTE=$(date +%M)
      CATEGORY_IDX=$((MINUTE / 5 % 5))
      case "$CATEGORY_IDX" in
        0) CATEGORY="a short productivity tip for a Linux developer" ;;
        1) CATEGORY="a brief NixOS fact or tip" ;;
        2) CATEGORY="a time-appropriate suggestion (it's ''${HOUR}:00)" ;;
        3) CATEGORY="a brief motivational one-liner for a developer" ;;
        4) CATEGORY="a short system observation based on the metrics" ;;
      esac

      PROMPT="Generate $CATEGORY. Context: uptime $UPTIME, RAM ''${RAM_PCT}%, disk $DISK_PCT, $WORKSPACES workspaces active, last NixOS commit $LAST_GIT. Output ONLY a single short sentence (max 60 chars), no quotes, no emoji."

      PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg m "$MODEL" --arg p "$PROMPT" '{model: $m, prompt: $p, stream: false}')
      RAW_RES=$(${pkgs.curl}/bin/curl -s --max-time 8 "$OLLAMA_URL" -d "$PAYLOAD" 2>/dev/null)
      TIP=$(echo "$RAW_RES" | ${pkgs.jq}/bin/jq -r '.response // empty' | head -n 1 | cut -c1-60 | sed 's/^"//;s/"$//')

      if [ -z "$TIP" ] || [ "$TIP" = "null" ]; then
        TIP="AI ambient unavailable"
      fi

      TOOLTIP="System: Up $UPTIME | RAM ''${RAM_PCT}% | Disk $DISK_PCT\nWorkspaces: $WORKSPACES | Last commit: $LAST_GIT"

      OUTPUT=$(${pkgs.jq}/bin/jq -n -c --arg text "󰧑 $TIP" --arg tooltip "$TOOLTIP" '{text: $text, tooltip: $tooltip}')
      echo "$OUTPUT" > "$CACHE_FILE"
      echo "$OUTPUT"
    '';
  };

  # Systemd User Services & Timers

  # Clipboard vector embedding daemon (semantic search)


  # Git AI Hook Integration

  programs.git.hooks.prepare-commit-msg = pkgs.writeShellScript "git-prepare-commit-msg" ''
    exec ~/.config/ai/git-prepare-commit-msg.sh "$@"
  '';

  # Nushell AI Shell Functions

  programs.nushell.extraConfig = ''
    # ── AI Session Helpers ──

    def get-ai-session-chat [] {
      if ("AI_CONVERSATION" in $env) { $env.AI_CONVERSATION } else { "" }
    }

    def get-home-file-context [prompt_text: string] {
      let lower = ($prompt_text | str downcase)
      mut ctx = ""
      if ("file" in $lower) or ("folder" in $lower) or ("dir" in $lower) or ("home" in $lower) or ("path" in $lower) {
        let tree = (${pkgs.fd}/bin/fd --max-depth 2 --hidden --exclude .git . /home/justkowal | ${pkgs.coreutils}/bin/head -n 40 | str join "\n")
        $ctx = "\n[Local Home Directory Files]:\n" + $tree + "\n"
      }
      $ctx
    }

    def --env query-ai-session [preferred_model: string, prompt_text: string] {
      let current_history = (get-ai-session-chat)
      let file_ctx = (get-home-file-context $prompt_text)
      let updated_history = $"($current_history)\n($file_ctx)User: ($prompt_text)\nAssistant:"
      let target = (resolve-model-name $preferred_model)
      let payload = ({model: $target, prompt: $updated_history, stream: false} | to json)
      let res = (http post --content-type application/json http://127.0.0.1:11434/api/generate $payload)
      let response_text = $res.response
      let new_history = $"($updated_history) ($response_text)\n"
      load-env { AI_CONVERSATION: $new_history }
      render-ai-response $response_text
    }

    def resolve-model-name [preferred: string] {
      try {
        let tags = (http get http://127.0.0.1:11434/api/tags)
        let names = ($tags.models | where name != "nomic-embed-text:latest" | get name)
        let matched = ($names | where { |n| ($n == $preferred) or ($n starts-with $preferred) or ($preferred starts-with $n) })
        if ($matched | is-not-empty) { ($matched | first) }
        else if ($names | is-not-empty) { ($names | first) }
        else { $preferred }
      } catch { $preferred }
    }

    def render-ai-response [text: string] {
      $text | ${pkgs.wl-clipboard}/bin/wl-copy
      ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i message-new-instant 2>/dev/null
      $text | ${pkgs.glow}/bin/glow -
    }

    # ── Model-Tiered AI Commands ──

    # E2B: Instant Shell Assistant
    def --env ai [...prompt: string] {
      let text = ($prompt | str join " ")
      if ($text | is-empty) { echo "Usage: ai <prompt>" }
      else { query-ai-session "hf.co/huihui-ai/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-GGUF" $text }
    }

    # E4B: Task & Code Assistant
    def --env ai-task [...prompt: string] {
      let text = ($prompt | str join " ")
      if ($text | is-empty) { echo "Usage: ai-task <prompt>" }
      else { query-ai-session "hf.co/huihui-ai/Huihui-gemma-4-E4B-it-qat-q4_0-unquantized-abliterated-GGUF" $text }
    }

    # 12B: Deep Analysis
    def --env ai-papa [...prompt: string] {
      let text = ($prompt | str join " ")
      if ($text | is-empty) { echo "Usage: ai-papa <prompt>" }
      else { query-ai-session "hf.co/huihui-ai/Huihui-gemma-4-12B-it-qat-q4_0-unquantized-abliterated-GGUF" $text }
    }

    # ── Utility Commands ──

    def ai-index [dir?: string] {
      let target = (if ($dir | is-empty) { "." } else { $dir })
      echo $"Indexing ($target)..."
      python3 ~/.config/ai/vector_indexer.py
      echo "Vector indexing complete!"
    }

    def vector-search [...query: string] {
      let text = ($query | str join " ")
      if ($text | is-empty) { echo "Usage: vector-search <query>" }
      else { python3 ~/.config/ai/vector_indexer.py --search $text }
    }

    def pdf-qa [file: string, ...question: string] {
      let q = ($question | str join " ")
      python3 ~/.config/ai/pdf_qa.py $file $q
    }

    def clip-search [...query: string] {
      let text = ($query | str join " ")
      python3 ~/.config/ai/clipboard_daemon.py --search $text
    }

    def git-ai [] {
      let diff = (git diff --staged)
      if ($diff | is-empty) {
        echo "No staged changes. Run 'git add <files>' first!"
      } else {
        echo "Generating commit message (E4B)..."
        let target = (resolve-model-name "hf.co/huihui-ai/Huihui-gemma-4-E4B-it-qat-q4_0-unquantized-abliterated-GGUF")
        let prompt = $"Generate a concise Conventional Commit message for:\n\n($diff)"
        let payload = ({model: $target, prompt: $prompt, stream: false} | to json)
        let res = (http post --content-type application/json http://127.0.0.1:11434/api/generate $payload)
        let msg = ($res.response | str trim)
        echo $"Proposed: ($msg)\n"
      }
    }

    def ai-debug [] {
      echo "Diagnosing system logs..."
      let journal = (journalctl -p err..emerg -n 25 --no-pager | str join "\n")
      let target = (resolve-model-name "hf.co/huihui-ai/Huihui-gemma-4-12B-it-qat-q4_0-unquantized-abliterated-GGUF")
      let prompt = $"Analyze these Linux error logs, explain root cause, and suggest fixes:\n\n($journal)"
      let payload = ({model: $target, prompt: $prompt, stream: false} | to json)
      let res = (http post --content-type application/json http://127.0.0.1:11434/api/generate $payload)
      render-ai-response $res.response
    }

    def ai-organize [dir?: string, --dry-run, --undo] {
      let script = $"($env.HOME)/.config/hypr/scripts/ai_organize.py"
      if $undo { python3 $script --undo }
      else if $dry_run {
        let target = (if ($dir | is-empty) { "~/Downloads" } else { $dir })
        python3 $script $target --dry-run
      } else {
        let target = (if ($dir | is-empty) { "~/Downloads" } else { $dir })
        python3 $script $target
      }
    }
  '';
}
