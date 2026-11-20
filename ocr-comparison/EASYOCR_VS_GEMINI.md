# EasyOCR vs Gemini vs Tesseract — Urdu OCR comparison (112_Edition.pdf)

**Date:** 19 Nov 2026 · **Test pages (same pages for all engines):** PDF p.1, p.23, p.24,
rendered with pdftoppm at 200 DPI (1654×2339 px). **File never left the VM.**
**Ground truth:** my visual reading of the rendered pages (`ground_truth.md`).
Counts below were scored by hand against that ground truth (±2 on borderline
partial/correct calls; one entry — p.1 key 97 — was unreadable to me visually
and is excluded from exact counts).

## Engines
| Engine | Version / setup | How run |
|---|---|---|
| EasyOCR | 1.7.2, `Reader(['ur','en'])`, CPU, torch 2.15.0+cu132 | This test, venv `ocr-comparison/venv` |
| Gemini vision | `gemini-3.5-flash-lite` (the model verified callable for this key; 2.5-flash-lite 404s) | Re-run today via registered `custom.gemini` connector (credential surrogate only, no key in any file). Prompt: exact transcription, left column then right. |
| Tesseract | tesseract.js v5, `urd+eng` | NOT re-run here — recorded earlier probe (19 Nov, same p.1 @ 200 DPI): English partially readable but garbled + columns interleaved; Urdu essentially unreadable. |

## Results

### Page 1 — key 61–100 (40 entries) + PAPER 246 title + Q1–19
| Check | Gemini | EasyOCR |
|---|---|---|
| Paper title | Exact | Recoverable with errors: `PPSC→PP5C`, `ID-194→\|0-194` |
| Key 61–86 (English, 26 entries) | **26/26** letters + values correct | **0/26** fully correct; ~13/26 values recognizable as fragments; letters systematically lost — `(B)` read as `(8)` |
| Urdu key 91–100 (8 entries: 91 والدہ, 92 تالیاں اور سیٹیاں بجانا, 93 فعل معروف, 94 شاعری, 95 بوکھلایا ہوا, 96 کام وام, 97 ?, 98 وہی, 99 حروف ربط, 100 الفاظ) | 5/8 exact (93, 94, 96, 99, 100); 95 partial (بوکھلایا ہوا → بوکھلا یا ہو آنا); 98 one-letter slip (وہی→وئی); 97 unverifiable | **1/8 exact** (100 الفاظ); ~3 partial (91, 94, 96, 99 as fragments); 4 essentially lost (93, 95, 97, 98) |
| Key 61–100 total, fully correct (number + letter + value) | ~36/40 | **1/40** (entry 100 only) |
| Questions Q1–19 | 19/19 stems, 76/76 options, exact | Stems ~17/19 recognizable as scattered fragments; option words ~60/76 present; option letters mostly lost/garbled; columns interleaved |

### Page 23 — English Q73–90 + Urdu Q91–96
| Check | Gemini | EasyOCR |
|---|---|---|
| English Q73–90 | All stems + options correct (Q84's options captured, detached to top of output) | ~70–80% of words present as fragments; letters garbled (`(A)→(8)/A١`); Q76 options mostly lost |
| Urdu Q91–96 stems | All correct except Q91 (C) مردوف→مروف (one letter) | Consistently glued/garbled: words run together with no spaces, e.g. `قافیہے بغیر نظم کہلاقے ؟`, `93 .بیک جاگوں حچنکائوٹا کامطلبے ؟` |
| Urdu Q91–96 options | All correct | ~60–70% of option words recognizable with effort; Q91–92 mostly wrong (گھوڑے→گوزے, بیل→یل, ہاتھی→انقی, مردوف→روف); Q93–96 options mostly recoverable |

### Page 24 — Urdu Q97–100 + full Answer Key Paper 250 (1–100)
| Check | Gemini | EasyOCR |
|---|---|---|
| Header `ANSWER KEY: Paper 250` | Exact | Exact |
| Key 1–100, fully correct (number + letter + value) | **99/100** (only 92: بیل→نیل, one letter) | **39/100** |
| Key 1–100, partial (value recognizable, letter/number lost or garbled) | 1 (the 92 slip) | **53/100** |
| Key 1–100, missing or wrong | 0 | **8/100**: 12 Indus missing, 21 (1976) missing, 24 (3) missing, 40 Silt missing, 65 (-2a)²ᵇ missing, 66 2496→`2236?`, 82 Approve of→`Bpprvn %h`, **92 (C) تیل for بیل — a WRONG answer that would corrupt the key** |
| Key letters correctly recovered | 99/100 | **≈39–42/100** |
| Urdu Q97–100 | All stems + options correct | Stems glued/garbled; options ~3/4 recognizable each |

## Speed (this VM: 1.5 shared vCPU, 6 GB RAM)
| Engine | Per page |
|---|---|
| EasyOCR | Model load 116.9 s cold / 6.0 s warm; OCR **493.8 s (p.1), 672.1 s (p.23), 490.4 s (p.24)** — ~8–11 min/page. Mean confidence 0.70–0.71; 49–71 lines/page below 0.5 confidence. |
| Gemini | **~8–11 s/page** wall time; 1,092 image tokens + ~1,100–1,300 output tokens/page. |
| Extrapolated 24-page book | EasyOCR ≈ **3.5–4.5 hours** on this VM class; Gemini ≈ **4 minutes**. |

## Install notes (for the record)
- **Attempt 1 FAILED:** pip download of the torch wheel (539 MB) hit `ERROR: Could not
  install packages due to an OSError: [Errno 28] No space left on device` at
  257.9/539.2 MB — because `/tmp` is a 512 MB tmpfs. (The `INSTALL rc=0` in that
  run was the `tail` pipeline's exit code, not pip's.)
- **Attempt 2 SUCCEEDED** with `TMPDIR` redirected into the workspace (~21 min total;
  egress ~2.5 MB/s). Installed: easyocr 1.7.2, torch 2.15.0+cu132, torchvision
  0.29.2. **venv is 5.8 GB** — PyPI torch bundles CUDA/nvidia packages; a CPU-only
  torch from the PyTorch CPU index would be ~1 GB. Model cache `~/.EasyOCR` is
  285 MB (craft_mlt_25k 83 MB + arabic recognizer 215 MB).
- Reading order: EasyOCR returns detection order, not reading order — the
  two-column layout (and the 4-column key) comes out interleaved. A naive
  mid-x column sort did not fix it (page skew + 4-column key); raw outputs are
  saved as-is (`easyocr_p*_raw.txt`, `_colsorted.txt`, `_words.json`).

## Cost / server estimate for a v2 EasyOCR route
- EasyOCR needs Python + torch on a server: cheapest suitable VPS ≈ **$20–40/mo**
  (4 vCPU class) + queue + maintenance. Even on 4–8 vCPU, expect ~2–4 min/page,
  i.e. a 24-page book ≈ **1–2 hours async** — not interactive. A GPU (T4) would
  cut it to seconds/page but costs ~$100+/mo always-on.
- Gemini at current 3.5-flash-lite rates ($0.30 in / $2.50 out per 1M tokens):
  ~1,092 image + ~1,200 output tokens ≈ **$0.0033/page → 24-page book ≈ $0.08
  (~Rs 22)**. (The older $0.0004/page figure was for the retired 2.5-flash-lite
  pricing.)
- Break-even: a $30/mo EasyOCR server costs the same as ~9,000 Gemini pages/mo
  (~375 books/mo). Below that volume Gemini is cheaper, ~50× faster, and far
  more accurate.

## Verdict — is EasyOCR viable as a v2 server route?
**No — not as the quality OCR route.** Measured on the user's real scanned paper:
- It recovers only **~40% of answer-key letters exactly** (39–42/100 on p.24,
  1/40 on p.1). The key letter is the whole point of a key — a parser fed this
  output would fail the app's own QA rules (never assign an unverified answer;
  ~60% of key letters would be missing or wrong).
- Urdu stems come out **glued together with dropped letters**; it even invents a
  wrong key value (تیل for بیل). Its failures are silent — wrong letters often
  carry high confidence (e.g. `(B)`→`(8)` at 0.9+).
- It is **~50× slower per page** than Gemini and needs a server the project
  would have to pay for and maintain, while Gemini costs ~Rs 22 per whole book.
- **Keep the current two tiers:** Tesseract (free/offline, English-leaning) +
  Gemini (best quality). EasyOCR's only honest role would be a no-cost fallback
  for English-heavy pages where the user manually corrects every answer — not
  recommended as a v2 server investment.
- If a non-Gemini Urdu route is ever required, **UTRNet** (92.97% on real Urdu
  lines, research code, server-side) is the better candidate to test next —
  not EasyOCR.

## Files in this folder
- `pages/p1-01.png`, `pages/p-23.png`, `pages/p-24.png` — 200 DPI renders
- `gemini_p1.txt`, `gemini_p23.txt`, `gemini_p24.txt` — Gemini transcriptions (re-run 19 Nov 2026)
- `easyocr_p1_*`, `easyocr_p23_*`, `easyocr_p24_*` — EasyOCR raw / text / column-sorted / words+json
- `ground_truth.md` — visual ground truth used for scoring
- `gemini_vision.py`, `run_easyocr.py`, `run_easyocr_batch.py` — runner scripts
- `venv/` — EasyOCR 1.7.2 + torch 2.15.0 (5.8 GB; CUDA-bundled)
