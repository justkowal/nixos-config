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
