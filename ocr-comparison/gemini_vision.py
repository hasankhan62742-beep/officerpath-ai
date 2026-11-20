"""Gemini vision transcription probe for OfficerPath AI OCR comparison.

Reads the API key ONLY through the registered custom.gemini credential
surrogate (never logged, never written to a file). Sends one page image
to gemini-3.5-flash-lite generateContent and saves the transcription text.

Usage: python3 gemini_vision.py <image.png> <out.txt> [model]
"""
import base64
import json
import sys
import urllib.request

sys.path.insert(0, "/opt/muse/skills/custom-connector-setup/bin")
from dynamic_credentials import add_surrogate_to_request, read_json_response

HOSTS = ["generativelanguage.googleapis.com"]


def transcribe(image_path: str, model: str) -> str:
    with open(image_path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode("ascii")
    prompt = (
        "Transcribe this scanned exam-paper page EXACTLY and COMPLETELY. "
        "Rules: reproduce every question number, option (A)(B)(C)(D) and its text, "
        "every answer-key entry (number, letter, answer text), and the paper title. "
        "Keep the two-column layout: transcribe the LEFT column top to bottom first, "
        "then the RIGHT column top to bottom. Reproduce Urdu text exactly in Urdu "
        "script, right-to-left as printed. Do not summarise, do not correct spelling, "
        "do not invent anything. If a word is unreadable, write [unreadable]. "
        "Output ONLY the transcription, no commentary."
    )
    body = {
        "contents": [
            {
                "parts": [
                    {"text": prompt},
                    {"inline_data": {"mime_type": "image/png", "data": b64}},
                ]
            }
        ],
        "generationConfig": {"temperature": 0},
    }
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    add_surrogate_to_request(req, "custom.gemini", allowed_hosts=HOSTS)
    with urllib.request.urlopen(req, timeout=300) as resp:
        payload = read_json_response(resp)
    cands = payload.get("candidates", [])
    if not cands:
        raise RuntimeError(f"no candidates: {json.dumps(payload)[:500]}")
    parts = cands[0].get("content", {}).get("parts", [])
    text = "".join(p.get("text", "") for p in parts)
    usage = payload.get("usageMetadata", {})
    return text, usage


if __name__ == "__main__":
    image_path, out_path = sys.argv[1], sys.argv[2]
    model = sys.argv[3] if len(sys.argv) > 3 else "gemini-3.5-flash-lite"
    text, usage = transcribe(image_path, model)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"model={model} chars={len(text)} usage={json.dumps(usage)} out={out_path}")
