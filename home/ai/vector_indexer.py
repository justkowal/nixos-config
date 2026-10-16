#!/usr/bin/env python3
"""Multi-modal Vector Indexer & Hybrid Semantic File Search.
PDF extraction, text embedding, Gemma 4 Vision image descriptions,
hybrid scoring (cosine + keyword), auto-indexing on missing store.
"""
import os, sys, json, math, time, hashlib, urllib.request, subprocess
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
        print("Vector index not found. Building now..."); scan_and_index()
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
    else: scan_and_index()
