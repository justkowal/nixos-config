#!/usr/bin/env python3
"""Smart AI File & Directory Organizer.
Categorizes files AND directories into intelligent, multi-level hierarchy.
Supports --dry-run and --undo with transaction logging.
"""
import sys, os, json, time, shutil, urllib.request, pathlib, subprocess

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
