"""Run EasyOCR (ur+en, CPU) on one page image and save raw results.

Usage: python3 run_easyocr.py <image.png> <out_prefix>
Writes:
  <out_prefix>_raw.txt    - one detected line per row: [conf] text (returned order)
  <out_prefix>_text.txt   - joined text in returned order
  <out_prefix>_colsorted.txt - text re-sorted: left column top->bottom, then right column
  <out_prefix>_words.json - full bbox/text/conf list + timings
"""
import json
import sys
import time

import easyocr


def column_sort(words, width):
    mid = width / 2.0
    left = [w for w in words if sum(p[0] for p in w[0]) / 4 < mid]
    right = [w for w in words if sum(p[0] for p in w[0]) / 4 >= mid]
    key = lambda w: sum(p[1] for p in w[0]) / 4  # mean y
    return sorted(left, key=key) + sorted(right, key=key)


def main():
    image_path, prefix = sys.argv[1], sys.argv[2]
    t0 = time.time()
    reader = easyocr.Reader(["ur", "en"], gpu=False, verbose=False)
    t_load = time.time() - t0
    print(f"model load: {t_load:.1f}s", flush=True)

    from PIL import Image
    width, height = Image.open(image_path).size
    t1 = time.time()
    result = reader.readtext(image_path)
    t_ocr = time.time() - t1
    print(f"ocr: {t_ocr:.1f}s, {len(result)} lines, image {width}x{height}", flush=True)

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
        "image": image_path,
        "size": [width, height],
        "model_load_s": round(t_load, 1),
        "ocr_s": round(t_ocr, 1),
        "lines": len(result),
        "mean_conf": round(sum(confs) / len(confs), 3) if confs else None,
        "words": [
            {"bbox": [[round(x), round(y)] for x, y in bbox], "text": text, "conf": round(conf, 3)}
            for bbox, text, conf in result
        ],
    }
    with open(f"{prefix}_words.json", "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    print(f"wrote {prefix}_*.txt/json")


if __name__ == "__main__":
    main()
