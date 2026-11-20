#!/usr/bin/env python3
"""Gemini vision OCR for the PPSC66 baseline measurement.

One generateContent call per page, using the app's own OCR prompt
(lib/services/urdu_ocr.dart GeminiVisionOcr) and the app's own model
(gemini-3.5-flash-lite) and settings (visionImageWidth 1000,
maxOutputTokens 2048, temperature 0.0).

Reads the API key only through the registered custom.gemini connection
surrogate (same pattern as gemini_tts.py). Never logs the key.

Usage:
  python3 gemini_vision_ocr.py <page-png> <out-txt> [--model ...]
"""
import argparse
import base64
import io
import json
import sys
import urllib.request

sys.path.insert(0, "/opt/muse/skills/custom-connector-setup/bin")
from dynamic_credentials import add_surrogate_to_request, read_json_response

from PIL import Image

HOSTS = ["generativelanguage.googleapis.com"]
DEFAULT_MODEL = "gemini-3.5-flash-lite"
PROMPT = (
    "Transcribe ALL text on this scanned book page EXACTLY as "
    "printed, line by line, in reading order (left column first, "
    "then right column). Keep Urdu script as Urdu script and "
    "English as English. Do not correct, translate, summarise or "
    "add anything. If a word is unreadable, write [?] for it."
)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        raise RuntimeError("redirect refused, verify the endpoint")


def to_jpeg_1000(png_path):
    img = Image.open(png_path).convert("RGB")
    w, h = img.size
    if w > 1000:
        img = img.resize((1000, int(h * 1000 / w)), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=88)
    return buf.getvalue()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("png", help="rendered page PNG")
    ap.add_argument("out", help="output text file")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--extra", default="",
                    help="extra instruction appended to the OCR prompt "
                    "(used only when the verbatim prompt is blocked by "
                    "the recitation filter; recorded in the report)")
    args = ap.parse_args()

    prompt = PROMPT + ((" " + args.extra) if args.extra else "")

    jpeg = to_jpeg_1000(args.png)
    payload = {
        "contents": [
            {
                "parts": [
                    {"text": prompt},
                    {
                        "inlineData": {
                            "mimeType": "image/jpeg",
                            "data": base64.b64encode(jpeg).decode("ascii"),
                        }
                    },
                ]
            }
        ],
        "generationConfig": {"maxOutputTokens": 2048, "temperature": 0.0},
    }
    url = (
        f"https://generativelanguage.googleapis.com/v1beta/models/"
        f"{args.model}:generateContent"
    )
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=body, method="POST")
    request.add_header("Content-Type", "application/json")
    add_surrogate_to_request(request, "custom.gemini", allowed_hosts=HOSTS)
    try:
        with urllib.request.build_opener(NoRedirect()).open(
            request, timeout=180
        ) as resp:
            data = read_json_response(resp)
    except urllib.error.HTTPError as exc:
        err = exc.read().decode("utf-8", errors="replace")[:800]
        print(f"HTTP {exc.code}: {err}", file=sys.stderr)
        return 1

    cands = data.get("candidates") or []
    if not cands:
        print("no candidates: " + json.dumps(data)[:600], file=sys.stderr)
        return 1
    parts = ((cands[0].get("content") or {}).get("parts") or [])
    text = "".join(p.get("text", "") for p in parts if isinstance(p, dict))
    if not text.strip():
        print("empty text: " + json.dumps(data)[:600], file=sys.stderr)
        return 1
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(text)
    usage = data.get("usageMetadata") or {}
    print(json.dumps({
        "model": args.model,
        "finish_reason": cands[0].get("finishReason"),
        "chars": len(text),
        "lines": text.count("\n") + 1,
        "usage": usage,
        "out": args.out,
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
