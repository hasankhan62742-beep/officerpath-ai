#!/usr/bin/env python3
"""Gemini vision OCR for one image (Worker 4 camera-photo task).

Modeled on ~/workspace/custom-connectors/custom.gemini/bin/gemini_tts.py:
reads the API key only through the registered custom.gemini connection
surrogate; never puts a key in a file, argument, environment variable
or log. Sends the image as inlineData + a transcription prompt and
prints the model's text to stdout (or --out file).

Usage:
  python3 gemini_vision_ocr.py --image IMG.jpg [--out out.txt]
      [--model gemini-2.5-flash] [--prompt "..."]
"""
import argparse
import base64
import io
import json
import sys
import urllib.error
import urllib.request

sys.path.insert(0, "/opt/muse/skills/custom-connector-setup/bin")
from dynamic_credentials import add_surrogate_to_request, read_json_response

HOSTS = ["generativelanguage.googleapis.com"]
DEFAULT_MODEL = "gemini-2.5-flash"
DEFAULT_PROMPT = (
    "Transcribe ALL printed text in this photo of a book page, exactly "
    "as printed, line by line, in reading order (left column top to "
    "bottom, then right column top to bottom). Preserve question "
    "numbers, option letters (A) (B) (C) (D), and every asterisk (*) "
    "exactly where it appears. Do NOT correct spelling, do NOT add or "
    "remove anything, do NOT summarise. If a word is unreadable, write "
    "[unreadable] for it. Handwritten notes at the bottom are NOT part "
    "of the printed page — transcribe them on separate lines prefixed "
    "with HANDWRITTEN: and nothing else."
)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        raise RuntimeError("redirect refused, verify the endpoint")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--out", default=None)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--prompt", default=DEFAULT_PROMPT)
    ap.add_argument("--max-dim", type=int, default=1600,
                    help="Downscale so the longest side is this many px.")
    args = ap.parse_args()

    try:
        from PIL import Image
        im = Image.open(args.image).convert("RGB")
        w, h = im.size
        scale = min(1.0, args.max_dim / max(w, h))
        if scale < 1.0:
            im = im.resize((int(w * scale), int(h * scale)),
                           Image.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, format="JPEG", quality=88)
        jpeg = buf.getvalue()
    except ImportError:
        with open(args.image, "rb") as f:
            jpeg = f.read()

    payload = {
        "contents": [{
            "parts": [
                {"text": args.prompt},
                {"inline_data": {
                    "mime_type": "image/jpeg",
                    "data": base64.b64encode(jpeg).decode("ascii"),
                }},
            ],
        }],
        "generationConfig": {"temperature": 0.0},
    }
    url = (f"https://generativelanguage.googleapis.com/v1beta/models/"
           f"{args.model}:generateContent")
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=body, method="POST")
    request.add_header("Content-Type", "application/json")
    add_surrogate_to_request(request, "custom.gemini", allowed_hosts=HOSTS)
    try:
        with urllib.request.build_opener(NoRedirect()).open(
                request, timeout=180) as resp:
            data = read_json_response(resp)
    except urllib.error.HTTPError as exc:
        err = exc.read().decode("utf-8", errors="replace")[:1200]
        print(f"HTTP {exc.code}: {err}", file=sys.stderr)
        return 1

    cands = data.get("candidates") or []
    if not cands:
        print("no candidates: " + json.dumps(data)[:800], file=sys.stderr)
        return 1
    parts = ((cands[0].get("content") or {}).get("parts") or [])
    text = "".join(p.get("text", "") for p in parts)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"wrote {args.out} ({len(text)} chars)", file=sys.stderr)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
