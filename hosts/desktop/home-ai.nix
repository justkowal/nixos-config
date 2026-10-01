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
    text = ''
      #!/usr/bin/env python3
      import sys, re, html

      def md_to_pango(text):
          if not text:
              return ""
          text = html.escape(text)
          text = re.sub(r'```(?:[a-zA-Z0-9_-]+)?\n?(.*?)```', r'<tt>\1</tt>', text, flags=re.DOTALL)
          text = re.sub(r'`([^`]+)`', r'<tt>\1</tt>', text)
          text = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', text)
          text = re.sub(r'__([^_]+)__', r'<b>\1</b>', text)
          text = re.sub(r'\*([^*]+)\*', r'<i>\1</i>', text)
          text = re.sub(r'_([^_]+)_', r'<i>\1</i>', text)
          text = re.sub(r'^#+\s*(.*)$', r'<b>\1</b>', text, flags=re.MULTILINE)
          return text

      if __name__ == "__main__":
          inp = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else sys.stdin.read()
          print(md_to_pango(inp))
    '';
  };

  # Interactive Rofi AI Popup with Handoff to Open-WebUI
  xdg.configFile."hypr/scripts/rofi_ai.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      PROMPT="$1"
      if [ -z "$PROMPT" ]; then
        PROMPT=$(${pkgs.rofi}/bin/rofi -dmenu -i -p "🤖 AI Assistant" -font "Outfit 12" -theme-str 'window {width: 650px;}')
      fi
      [ -z "$PROMPT" ] && exit 0

      TAGS=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/tags 2>/dev/null || echo '{}')
      PREF_MODEL="hf.co/huihui-ai/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-GGUF"
      TARGET_MODEL=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r --arg pref "$PREF_MODEL" '.models[]? | select(.name != "nomic-embed-text:latest") | .name | select(contains($pref))' | head -n 1)
      FIRST_MODEL=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r '.models[]? | select(.name != "nomic-embed-text:latest") | .name' | head -n 1)
      MODEL="''${TARGET_MODEL:-''${FIRST_MODEL:-$PREF_MODEL}}"

      ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:rofi-ai "🤖 AI Assistant" "Thinking with model: $MODEL..." -i dialog-information

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
        CHOICE=$(echo -e "💬 Ask Follow-up Question\n📋 Copy Response to Clipboard\n🌐 Open in Open-WebUI\n❌ Close" | ${pkgs.rofi}/bin/rofi -dmenu -i -p "AI Response" -mesg "$RESPONSE" -font "Outfit 11" -theme-str 'window {width: 850px;} message {border: 2px; border-radius: 12px; padding: 12px; margin: 0px 0px 10px 0px;} textbox {wrap: true;} listview {lines: 4;} element {padding: 8px;}')

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
          TYPED_REPLY=$(echo "$CHOICE" | ${pkgs.gnused}/bin/sed -E 's/^\s*💬\s*Ask Follow-up Question.*\s*//')
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
        ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:ai-vision "👁️ Vision AI" "Analyzing screenshot contents..." -i image-x-generic

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
            CHOICE=$(echo -e "💬 Ask Follow-up Question about Screenshot\n📋 Copy Analysis to Clipboard\n🌐 Open in Open-WebUI\n❌ Close" | ${pkgs.rofi}/bin/rofi -dmenu -i -p "AI Screenshot Analysis" -mesg "$RESPONSE" -font "Outfit 11" -theme-str 'window {width: 850px;} message {border: 2px; border-radius: 12px; padding: 12px; margin: 0px 0px 10px 0px;} textbox {wrap: true;} listview {lines: 4;} element {padding: 8px;}')

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
              TYPED_REPLY=$(echo "$CHOICE" | ${pkgs.gnused}/bin/sed -E 's/^\s*💬\s*Ask Follow-up Question.*\s*//')
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
    text = ''
      #!/usr/bin/env python3
      """Smart AI File & Directory Organizer.
      Categorizes files AND directories into intelligent, multi-level hierarchy.
      Supports --dry-run and --undo with transaction logging.
      """
      import sys, os, glob, json, time, shutil, urllib.request, pathlib, subprocess

      LOG_FILE = os.path.expanduser("~/.local/state/ai-organize.log")
      HOME = os.path.expanduser("~")

      ROOT_GUIDELINES = [
          "Documents/PDFs", "Documents/Notes", "Documents/Docs", "Documents/Invoices",
          "Documents/Lectures", "Documents/Books",
          "Projects/NixOS", "Projects/Code", "Projects/CAD", "Projects/Web",
          "Pictures/Screenshots", "Pictures/Wallpapers", "Pictures/Photos",
          "Media/Videos", "Media/Audio", "Media/Podcasts",
          "CAD/3D_Prints", "CAD/Schematics",
          "Downloads/Archives", "Downloads/Installers"
      ]

      def inspect_item(target_dir, name):
          full_path = os.path.join(target_dir, name)
          is_dir = os.path.isdir(full_path)
          ext = pathlib.Path(name).suffix.lower()
          preview = ""
          if is_dir:
              try:
                  sub_items = [f for f in os.listdir(full_path) if not f.startswith(".")][:8]
                  preview = f"[Directory containing {len(sub_items)} items: {', '.join(sub_items)}]"
              except Exception:
                  preview = "[Directory]"
          else:
              if ext in [".txt", ".md", ".org", ".json", ".nix", ".py", ".rs", ".js"]:
                  try:
                      with open(full_path, "r", encoding="utf-8", errors="ignore") as f:
                          preview = f.read(500).replace("\n", " ")
                  except Exception: pass
              elif ext == ".pdf":
                  try:
                      res = subprocess.run(["pdftotext", full_path, "-"], capture_output=True, text=True, timeout=3)
                      if res.stdout.strip():
                          preview = f"[PDF Text]: {res.stdout.strip()[:500].replace(chr(10), ' ')}"
                  except Exception: pass
          return is_dir, ext, preview

      def ask_ollama(name, is_dir, ext, preview):
          item_type = "directory" if is_dir else f"file (extension '{ext}')"
          prompt = f"""Categorize this {item_type} named '{name}'.
      Preview/Info: {preview}
      Propose a clean relative subpath inside $HOME. Return ONLY JSON: {{"path": "Relative/Subfolder/Path"}}"""
          payload = json.dumps({
              "model": "hf.co/huihui-ai/Huihui-gemma-4-E4B-it-qat-q4_0-unquantized-abliterated-GGUF",
              "prompt": prompt, "format": "json", "stream": False
          }).encode("utf-8")
          req = urllib.request.Request("http://127.0.0.1:11434/api/generate", data=payload,
                                       headers={"Content-Type": "application/json"})
          try:
              with urllib.request.urlopen(req, timeout=6) as res:
                  data = json.loads(res.read().decode("utf-8"))
                  parsed = json.loads(data.get("response", "{}"))
                  rel_path = parsed.get("path", "").strip("/")
                  if rel_path and not rel_path.startswith(".") and ".." not in rel_path:
                      return rel_path
          except Exception: pass
          return None

      def fallback_category(name, is_dir, ext):
          name_lower = name.lower()
          if is_dir:
              if any(k in name_lower for k in ["nix", "config", "dotfile"]): return "Projects/NixOS"
              if any(k in name_lower for k in ["cad", "stl", "step", "kicad"]): return "CAD/3D_Models"
              if any(k in name_lower for k in ["lecture", "course", "notes"]): return "Documents/Lectures"
              return "Documents/Folders"
          if ext in [".pdf"]: return "Documents/PDFs"
          if ext in [".md", ".txt", ".org"]: return "Documents/Notes"
          if ext in [".docx", ".doc", ".odt"]: return "Documents/Docs"
          if ext in [".png", ".jpg", ".jpeg", ".webp", ".svg"]:
              if "screen" in name_lower or "snap" in name_lower: return "Pictures/Screenshots"
              if "wall" in name_lower or "bg" in name_lower: return "Pictures/Wallpapers"
              return "Pictures"
          if ext in [".zip", ".tar.gz", ".tar.xz", ".7z", ".rar", ".tar.zst"]: return "Downloads/Archives"
          if ext in [".appimage", ".deb", ".rpm", ".iso", ".img"]: return "Downloads/Installers"
          if ext in [".fcstd", ".kicad_pcb", ".kicad_sch", ".stl", ".step", ".3mf"]: return "CAD"
          if ext in [".mp4", ".mkv", ".webm", ".avi", ".mov"]: return "Media/Videos"
          if ext in [".mp3", ".flac", ".wav", ".ogg", ".m4a"]: return "Media/Audio"
          return "Downloads/Miscellaneous"

      PROTECTED_KEYWORDS = [
          "cyberpunk", "repack", "dodi", "fitgirl", "steam", "steamapps",
          "wine", ".wine", "lutris", "heroic", "virtualbox", "qemu",
          "distrobox", "docker", "game", "games"
      ]

      def is_protected(name, is_dir, src_path):
          name_lower = name.lower()
          if any(k in name_lower for k in PROTECTED_KEYWORDS):
              return True, "Name contains protected keyword"
          if is_dir:
              try:
                  sub_files = [f.lower() for f in os.listdir(src_path)]
                  if any(k in f for f in sub_files for k in ["setup.exe", "game.exe", ".bin"]):
                      return True, "Directory contains game/installer executables"
                  if len(sub_files) > 100:
                      return True, "Directory contains >100 files"
              except Exception: pass
          return False, ""

      def undo():
          if not os.path.exists(LOG_FILE):
              print("No log file found."); return
          with open(LOG_FILE, "r") as f: lines = f.readlines()
          if not lines: print("Log file is empty."); return
          for line in reversed(lines):
              if "MOVED:" in line:
                  try:
                      parts = line.strip().split("MOVED: ")[1].split(" -> ")
                      src, dst = parts[0], parts[1]
                      if os.path.exists(dst):
                          os.makedirs(os.path.dirname(src), exist_ok=True)
                          shutil.move(dst, src)
                          print(f"Restored: {dst} -> {src}")
                  except Exception as e: print(f"Error: {e}")
          open(LOG_FILE, "w").close()
          print("Undo complete!")

      def organize(target_dir, dry_run=False):
          target_dir = os.path.expanduser(target_dir)
          if not os.path.exists(target_dir): print(f"Not found: {target_dir}"); return
          os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
          items = [f for f in os.listdir(target_dir) if not f.startswith(".")]
          print(f"Scanning '{target_dir}' ({len(items)} items, Dry Run: {dry_run})...")
          for item in items:
              src_path = os.path.join(target_dir, item)
              is_dir, ext, preview = inspect_item(target_dir, item)
              protected, reason = is_protected(item, is_dir, src_path)
              if protected: print(f"[SKIP] '{item}': {reason}"); continue
              rel_dest = ask_ollama(item, is_dir, ext, preview)
              if not rel_dest: rel_dest = fallback_category(item, is_dir, ext)
              dest_dir = os.path.join(HOME, rel_dest)
              dest_path = os.path.join(dest_dir, item)
              if src_path == dest_path or dest_path.startswith(src_path): continue
              if dry_run:
                  print(f"[DRY-RUN] '{item}' -> '{rel_dest}/'")
              else:
                  os.makedirs(dest_dir, exist_ok=True)
                  shutil.move(src_path, dest_path)
                  with open(LOG_FILE, "a") as log:
                      log.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] MOVED: {src_path} -> {dest_path}\n")
                  print(f"MOVED: '{item}' -> '{rel_dest}/'")

      if __name__ == "__main__":
          if len(sys.argv) > 1 and sys.argv[1] == "--undo": undo()
          else:
              dry = "--dry-run" in sys.argv
              target = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "~/Downloads"
              organize(target, dry_run=dry)
    '';
  };

  # ─── AI Clipboard Manager (Vector-embedded persistent history) ─────────

  xdg.configFile."ai/clipboard_daemon.py" = {
    executable = true;
    text = ''
      #!/usr/bin/env python3
      """AI Clipboard Manager — Vector-embedded clipboard history with semantic search."""
      import os, sys, json, math, time, hashlib, subprocess, urllib.request

      OLLAMA_EMBED_URL = "http://127.0.0.1:11434/api/embed"
      EMBED_MODEL = "nomic-embed-text"
      CLIP_STORE = os.path.expanduser("~/.local/share/clipboard_vectors.json")
      MAX_ENTRIES = 200

      def get_embedding(text):
          payload = json.dumps({"model": EMBED_MODEL, "input": text[:2000]}).encode("utf-8")
          req = urllib.request.Request(OLLAMA_EMBED_URL, data=payload, headers={"Content-Type": "application/json"})
          try:
              with urllib.request.urlopen(req, timeout=5) as res:
                  data = json.loads(res.read().decode("utf-8"))
                  embeds = data.get("embeddings", [])
                  return embeds[0] if embeds else []
          except Exception: return []

      def cosine_sim(a, b):
          if not a or not b or len(a) != len(b): return 0.0
          dot = sum(x * y for x, y in zip(a, b))
          na = math.sqrt(sum(x * x for x in a))
          nb = math.sqrt(sum(x * x for x in b))
          return dot / (na * nb) if na and nb else 0.0

      def watch():
          os.makedirs(os.path.dirname(CLIP_STORE), exist_ok=True)
          last_text = ""
          print("AI Clipboard daemon running...")
          while True:
              try:
                  res = subprocess.run(["wl-paste", "-n"], capture_output=True, text=True, timeout=2)
                  text = res.stdout.strip()
                  if text and text != last_text and len(text) > 3:
                      last_text = text
                      emb = get_embedding(text)
                      entry = {"timestamp": int(time.time()), "text": text,
                               "hash": hashlib.md5(text.encode()).hexdigest(), "vector": emb}
                      history = []
                      if os.path.exists(CLIP_STORE):
                          try:
                              with open(CLIP_STORE, "r") as f: history = json.load(f)
                          except Exception: pass
                      history = [h for h in history if h.get("hash") != entry["hash"]]
                      history.insert(0, entry)
                      history = history[:MAX_ENTRIES]
                      with open(CLIP_STORE, "w") as f: json.dump(history, f)
              except Exception: pass
              time.sleep(1.5)

      def search(query, top_k=5):
          if not os.path.exists(CLIP_STORE): print("No clipboard store found."); return
          q_emb = get_embedding(query)
          if not q_emb: print("Failed to embed query."); return
          with open(CLIP_STORE, "r") as f: history = json.load(f)
          scored = [(cosine_sim(q_emb, item.get("vector", [])), item["text"]) for item in history]
          scored.sort(key=lambda x: x[0], reverse=True)
          print(f"\n=== Clipboard Semantic Search: '{query}' ===\n")
          for score, text in scored[:top_k]:
              print(f"[{score:.4f}] {text.replace(chr(10), ' ')[:100]}")

      if __name__ == "__main__":
          if len(sys.argv) > 1 and sys.argv[1] == "--watch": watch()
          elif len(sys.argv) > 1 and sys.argv[1] == "--search": search(" ".join(sys.argv[2:]))
          else: print("Usage: clipboard_daemon.py --watch | --search <query>")
    '';
  };

  # ─── PDF Q&A Tool ──────────────────────────────────────────────────────

  xdg.configFile."ai/pdf_qa.py" = {
    executable = true;
    text = ''
      #!/usr/bin/env python3
      """PDF Q&A CLI Tool — Fast local RAG on any PDF using pdftotext & Ollama."""
      import sys, os, json, subprocess, urllib.request

      OLLAMA_URL = "http://127.0.0.1:11434/api/generate"
      MODEL = "hf.co/huihui-ai/Huihui-gemma-4-E4B-it-qat-q4_0-unquantized-abliterated-GGUF"

      def extract_text(pdf_path):
          try:
              res = subprocess.run(["pdftotext", pdf_path, "-"], capture_output=True, text=True, check=True)
              return res.stdout
          except Exception as e: print(f"Error extracting PDF: {e}"); sys.exit(1)

      def ask_question(text, question):
          context = text[:12000]
          prompt = f"Context from PDF:\n{context}\n\nQuestion: {question}\nAnswer concisely based ONLY on context:"
          payload = json.dumps({"model": MODEL, "prompt": prompt, "stream": False}).encode("utf-8")
          req = urllib.request.Request(OLLAMA_URL, data=payload, headers={"Content-Type": "application/json"})
          try:
              with urllib.request.urlopen(req, timeout=30) as res:
                  data = json.loads(res.read().decode("utf-8"))
                  print("\n💡 AI Answer:\n")
                  print(data.get("response", "No response generated."))
          except Exception as e: print(f"Ollama API Error: {e}")

      if __name__ == "__main__":
          if len(sys.argv) < 2: print("Usage: pdf_qa.py <file.pdf> [question]"); sys.exit(1)
          pdf_file = sys.argv[1]
          if not os.path.exists(pdf_file): print(f"Not found: {pdf_file}"); sys.exit(1)
          text = extract_text(pdf_file)
          question = " ".join(sys.argv[2:]) if len(sys.argv) > 2 else input("Ask a question: ")
          ask_question(text, question)
    '';
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
          "🔔 AI Digest ($NOTIF_COUNT notifications)" "$RESPONSE" -i dialog-information
      else
        echo ""
        echo "🔔 AI Notification Digest ($NOTIF_COUNT notifications)"
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
    text = ''
      #!/usr/bin/env python3
      """Multi-modal Vector Indexer & Hybrid Semantic File Search.
      PDF extraction, text embedding, Gemma 4 Vision image descriptions,
      hybrid scoring (cosine + keyword), auto-indexing on missing store.
      """
      import os, sys, json, math, time, base64, hashlib, urllib.request, subprocess
      from pathlib import Path

      OLLAMA_EMBED_URL = "http://127.0.0.1:11434/api/embed"
      OLLAMA_GEN_URL = "http://127.0.0.1:11434/api/generate"
      VISION_MODEL = "hf.co/huihui-ai/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-GGUF:latest"
      EMBED_MODEL = "nomic-embed-text"
      VECTOR_STORE = os.path.expanduser("~/.local/share/home_vectors.json")
      HOME = os.path.expanduser("~")

      EXCLUDE_SUB = {".git", "node_modules", ".direnv", "result", "__pycache__", ".cache",
                     "target", "build", "dist", ".next", "venv", ".venv"}
      EXCLUDE_EXT = {".zip", ".tar", ".gz", ".xz", ".7z", ".bin", ".iso", ".exe",
                     ".so", ".o", ".a", ".dll", ".pyc", ".lock", ".db", ".sqlite"}
      IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp"}

      def is_system_busy():
          try:
              if os.path.exists("/sys/class/drm/card1/device/gpu_busy_percent"):
                  with open("/sys/class/drm/card1/device/gpu_busy_percent") as f:
                      if int(f.read().strip()) > 15: return True
              load1, _, _ = os.getloadavg()
              if load1 / (os.cpu_count() or 1) > 0.35: return True
              res = subprocess.run(["pgrep", "-i", "-x", "steam|gamescope|lutris|heroic|java|obs|ffmpeg|nix-daemon|hyprlock"], capture_output=True)
              if res.returncode == 0: return True
          except Exception: pass
          return False

      def get_embedding(text):
          payload = json.dumps({"model": EMBED_MODEL, "input": text[:2000]}).encode("utf-8")
          req = urllib.request.Request(OLLAMA_EMBED_URL, data=payload, headers={"Content-Type": "application/json"})
          try:
              with urllib.request.urlopen(req, timeout=15) as r:
                  d = json.loads(r.read().decode("utf-8"))
                  e = d.get("embeddings", [])
                  return e[0] if e else []
          except Exception: return []

      def describe_image(path):
          # Skip heavy vision model inference during background auto-indexing sweeps
          return ""

      def extract_pdf_text(path):
          try:
              res = subprocess.run(["pdftotext", path, "-"], capture_output=True, text=True, timeout=5)
              return res.stdout.strip()[:2000]
          except Exception: return ""

      def cosine_sim(a, b):
          if not a or not b or len(a) != len(b): return 0.0
          dot = sum(x * y for x, y in zip(a, b))
          na = math.sqrt(sum(x * x for x in a))
          nb = math.sqrt(sum(x * x for x in b))
          return dot / (na * nb) if na and nb else 0.0

      def fp(path):
          try:
              s = os.stat(path)
              return hashlib.md5(f"{path}:{s.st_mtime_ns}:{s.st_size}".encode()).hexdigest()
          except Exception: return ""

      def extract_desc(path):
          fn, par, ext = Path(path).name, Path(path).parent.name, Path(path).suffix.lower()
          try: mb = os.path.getsize(path) / (1024 * 1024)
          except: return ""
          if ext in IMAGE_EXTS:
              if mb > 10: return f"[Image] '{fn}' in '{par}'. Path: {path}."
              d = describe_image(path)
              return f"[Image] '{fn}' in '{par}'. Visual: {d}. Path: {path}." if d else f"[Image] '{fn}' in '{par}'. Path: {path}."
          if ext in {".pdf"}:
              txt = extract_pdf_text(path)
              return f"[PDF '{fn}' in '{par}'] Content: {txt}" if txt else f"[PDF] '{fn}' in '{par}'. Path: {path}."
          if ext in {".mp3", ".wav", ".flac", ".ogg", ".m4a"}: return f"[Audio] '{fn}' in '{par}'. Path: {path}."
          if ext in {".mp4", ".mkv", ".avi", ".webm", ".mov"}: return f"[Video] '{fn}' in '{par}'. Path: {path}."
          try:
              with open(path, "r", encoding="utf-8", errors="ignore") as f: c = f.read(1800)
              if c.strip(): return f"[File '{fn}' in '{par}'] Content: {c}"
          except: pass
          return f"[File] '{fn}' in '{par}'. Path: {path}."

      def scan():
          valid = []
          for root, dirs, files in os.walk(HOME):
              dirs[:] = [x for x in dirs if x not in EXCLUDE_SUB and not x.startswith(".")]
              for f in files:
                  if f.startswith("."): continue
                  ext = Path(f).suffix.lower()
                  if ext in EXCLUDE_EXT: continue
                  full = os.path.join(root, f)
                  try:
                      sz = os.path.getsize(full)
                      if ext in IMAGE_EXTS and 100 < sz < 10 * 1024 * 1024: valid.append(full)
                      elif 10 < sz < 2 * 1024 * 1024: valid.append(full)
                  except: pass
          return valid

      def scan_and_index():
          if is_system_busy():
              sys.exit(0)
          os.makedirs(os.path.dirname(VECTOR_STORE), exist_ok=True)
          existing = []
          if os.path.exists(VECTOR_STORE):
              try:
                  with open(VECTOR_STORE) as f: existing = json.load(f)
              except: pass
          efp = {r.get("fp", ""): r for r in existing if r.get("fp")}
          files = scan()
          print(f"Scanning {len(files)} files for vector indexing...")
          records = []; new = 0; reused = 0; t0 = time.time()
          for i, path in enumerate(files):
              f = fp(path)
              if not f: continue
              if f in efp: records.append(efp[f]); reused += 1
              else:
                  desc = extract_desc(path)
                  if not desc: continue
                  emb = get_embedding(desc)
                  if emb: records.append({"path": path, "fp": f, "snippet": desc[:300].replace("\n", " "), "vector": emb}); new += 1
              if (i + 1) % 50 == 0: print(f"  [{i+1}/{len(files)}] new={new} reused={reused} ({time.time()-t0:.0f}s)")
          with open(VECTOR_STORE, "w") as f: json.dump(records, f)
          print(f"Done! {len(records)} records ({new} new, {reused} reused) in {time.time()-t0:.0f}s")

      def search(query, top_k=8):
          if not os.path.exists(VECTOR_STORE) or os.path.getsize(VECTOR_STORE) < 10:
              print("Vector index not found. Building now..."); index()
          qe = get_embedding(query)
          q_terms = [t.lower() for t in query.split() if len(t) > 1]
          with open(VECTOR_STORE) as f: recs = json.load(f)
          scored = []
          for r in recs:
              vec_score = cosine_sim(qe, r.get("vector", [])) if qe else 0.0
              path_str = r.get("path", "").lower()
              snip_str = r.get("snippet", "").lower()
              kw_score = 0.0
              for term in q_terms:
                  if term in os.path.basename(path_str): kw_score += 0.5
                  elif term in path_str: kw_score += 0.3
                  if term in snip_str: kw_score += 0.2
              kw_score = min(1.0, kw_score)
              final_score = 0.55 * vec_score + 0.45 * kw_score
              scored.append({"path": r["path"], "score": final_score, "vec": vec_score, "kw": kw_score, "snippet": r.get("snippet", "")})
          scored = sorted(scored, key=lambda x: x["score"], reverse=True)[:top_k]
          print(f"\n=== Vector Matches: '{query}' ===\n")
          for r in scored:
              print(f"  [{r['score']:.4f}] (vec: {r['vec']:.2f}, kw: {r['kw']:.2f}) {r['path']}")
              print(f"           {r['snippet'][:130]}\n")

      if __name__ == "__main__":
          if len(sys.argv) > 1 and sys.argv[1] == "--search": search(" ".join(sys.argv[2:]))
          else: index()
    '';
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
          CHOICE=$(echo -e "📖 Response Summary: $SUMMARY_TEXT\n💬 Continue Chat\n📋 Copy Response\n🌐 Open in Open-WebUI\n❌ Close" | rofi -dmenu -i -p "Spotlight AI ($MODEL_LABEL)" -mesg "$RESPONSE" -font "Outfit 11" -theme-str 'window {width: 850px;} message {border: 2px; border-radius: 12px; padding: 12px; margin: 0px 0px 10px 0px;} textbox {wrap: true;} listview {lines: 5;} element {padding: 8px;}')

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
            TYPED_REPLY=$(echo "$CHOICE" | ${pkgs.gnused}/bin/sed -E 's/^\s*(📖|💬|📋|🌐|❌).*\s*//')
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

      # ── NEW: AI Instant Answer Fallback (E2B) ──
      # When nothing matched, try a quick local LLM answer before falling to web
      AI_FALLBACK_MODEL="hf.co/huihui-ai/Huihui-gemma-4-E2B-it-qat-q4_0-unquantized-abliterated-GGUF"
      TAGS=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:11434/api/tags 2>/dev/null || echo '{}')
      FB_MODEL=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r --arg pref "$AI_FALLBACK_MODEL" '.models[]? | .name | select(contains($pref))' | head -n 1)
      FB_FIRST=$(echo "$TAGS" | ${pkgs.jq}/bin/jq -r '.models[]? | select(.name != "nomic-embed-text:latest") | .name' | head -n 1)
      FB_TARGET="''${FB_MODEL:-''${FB_FIRST:-$AI_FALLBACK_MODEL}}"

      FB_PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg m "$FB_TARGET" --arg p "Answer in 1-2 sentences: $CLEAN_INPUT" '{model: $m, prompt: $p, stream: false}')
      FB_RES=$(${pkgs.curl}/bin/curl -s --max-time 5 http://127.0.0.1:11434/api/generate -d "$FB_PAYLOAD" 2>/dev/null)
      FB_ANSWER=$(echo "$FB_RES" | ${pkgs.jq}/bin/jq -r '.response // empty' 2>/dev/null)

      if [ -n "$FB_ANSWER" ] && [ "$FB_ANSWER" != "null" ] && [ ''${#FB_ANSWER} -gt 5 ]; then
        echo "$FB_ANSWER" | ${pkgs.wl-clipboard}/bin/wl-copy
        ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:spotlight-ai "✨ Spotlight AI" "$FB_ANSWER" -i dialog-information
      fi

      # Always fall through to web search as secondary
      ENCODED=$(${pkgs.jq}/bin/jq -rr --arg q "$CLEAN_INPUT" '$q | @uri')
      ${pkgs.xdg-utils}/bin/xdg-open "http://127.0.0.1:8888/search?q=$ENCODED"
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

        ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:clip-ai "🧠 Clipboard AI" "Processing..." -i dialog-information

        local PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg m "$MODEL" --arg p "$PROMPT" '{model: $m, prompt: $p, stream: false}')
        local RAW_RES=$(${pkgs.curl}/bin/curl -s "$OLLAMA_URL" -d "$PAYLOAD" 2>/dev/null)
        local RESPONSE=$(echo "$RAW_RES" | ${pkgs.jq}/bin/jq -r '.response // empty')

        if [ -n "$RESPONSE" ] && [ "$RESPONSE" != "null" ]; then
          echo "$RESPONSE" | ${pkgs.wl-clipboard}/bin/wl-copy
          ${pkgs.libnotify}/bin/notify-send -h string:x-canonical-private-synchronous:clip-ai "✅ Clipboard AI" "$RESPONSE" -i dialog-information
        fi
      }

      offer_actions() {
        local content_type="$1"
        local text="$2"
        local preview=$(echo "$text" | head -c 80 | tr '\n' ' ')

        case "$content_type" in
          code)
            CHOICE=$(echo -e "✨ Format Code\n💡 Explain Code\n❌ Dismiss" | ${pkgs.rofi}/bin/rofi -dmenu -i -p "📋 Code Detected" -mesg "$preview" -font "Outfit 11" -theme-str 'window {width: 500px;} listview {lines: 3;}')
            if [[ "$CHOICE" =~ "Format" ]]; then do_ai_action "format_code" "$text"
            elif [[ "$CHOICE" =~ "Explain" ]]; then do_ai_action "explain_code" "$text"
            fi ;;
          url)
            CHOICE=$(echo -e "📝 Summarize Page\n❌ Dismiss" | ${pkgs.rofi}/bin/rofi -dmenu -i -p "🔗 URL Detected" -mesg "$preview" -font "Outfit 11" -theme-str 'window {width: 500px;} listview {lines: 2;}')
            [[ "$CHOICE" =~ "Summarize" ]] && do_ai_action "summarize_url" "$text"
            ;;
          error)
            CHOICE=$(echo -e "🔍 Diagnose Error\n❌ Dismiss" | ${pkgs.rofi}/bin/rofi -dmenu -i -p "⚠️ Error Detected" -mesg "$preview" -font "Outfit 11" -theme-str 'window {width: 500px;} listview {lines: 2;}')
            [[ "$CHOICE" =~ "Diagnose" ]] && do_ai_action "diagnose_error" "$text"
            ;;
          prose)
            CHOICE=$(echo -e "📝 Summarize\n🌍 Translate\n❌ Dismiss" | ${pkgs.rofi}/bin/rofi -dmenu -i -p "📄 Text Detected" -mesg "$preview" -font "Outfit 11" -theme-str 'window {width: 500px;} listview {lines: 3;}')
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
          "🩺 System Health" "$PANGO_RES" -i dialog-warning
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
          "📁 Auto-Organized" "$filename → $category/" -i folder
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

      OUTPUT=$(${pkgs.jq}/bin/jq -n -c --arg text "✨ $TIP" --arg tooltip "$TOOLTIP" '{text: $text, tooltip: $tooltip}')
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
