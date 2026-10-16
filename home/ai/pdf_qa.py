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
            print("\nAI Answer:\n")
            print(data.get("response", "No response generated."))
    except Exception as e: print(f"Ollama API Error: {e}")

if __name__ == "__main__":
    if len(sys.argv) < 2: print("Usage: pdf_qa.py <file.pdf> [question]"); sys.exit(1)
    pdf_file = sys.argv[1]
    if not os.path.exists(pdf_file): print(f"Not found: {pdf_file}"); sys.exit(1)
    text = extract_text(pdf_file)
    question = " ".join(sys.argv[2:]) if len(sys.argv) > 2 else input("Ask a question: ")
    ask_question(text, question)
