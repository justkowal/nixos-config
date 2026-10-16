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
