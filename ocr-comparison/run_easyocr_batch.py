"""Run EasyOCR on multiple pages with ONE model load (saves ~2 min/page)."""
import json
import sys
import time

import easyocr
from run_easyocr import column_sort

t0 = time.time()
reader = easyocr.Reader(["ur", "en"], gpu=False, verbose=False)
print(f"model load: {time.time() - t0:.1f}s", flush=True)

from PIL import Image

for image_path, prefix in [("pages/p-23.png", "easyocr_p23"), ("pages/p-24.png", "easyocr_p24")]:
    width, height = Image.open(image_path).size
    t1 = time.time()
    result = reader.readtext(image_path)
    t_ocr = time.time() - t1
    print(f"{image_path}: ocr {t_ocr:.1f}s, {len(result)} lines", flush=True)
    with open(f"{prefix}_raw.txt", "w", encoding="utf-8") as f:
        for bbox, text, conf in result:
            f.write(f"[{conf:.2f}] {text}\n")
    with open(f"{prefix}_text.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(text for _, text, _ in result))
    ordered = column_sort(result, width)
    with open(f"{prefix}_colsorted.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(text for _, text, _ in ordered))
    confs = [c for _, _, c in result]
    data = {
        "image": image_path, "size": [width, height],
        "ocr_s": round(t_ocr, 1), "lines": len(result),
        "mean_conf": round(sum(confs) / len(confs), 3) if confs else None,
        "words": [
            {"bbox": [[round(x), round(y)] for x, y in bbox], "text": text, "conf": round(conf, 3)}
            for bbox, text, conf in result
        ],
    }
    with open(f"{prefix}_words.json", "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    print(f"wrote {prefix}_*", flush=True)
print("DONE")
