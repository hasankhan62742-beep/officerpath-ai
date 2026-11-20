import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Camera-photo preprocessing for the Tesseract OCR tier (v1.3).
///
/// A phone photo of a book page has shadows, glare, uneven light and
/// colour cast — all of which hurt Tesseract (the weakest OCR tier).
/// This enhances the image before Tesseract sees it:
///
/// 1. grayscale — colour carries no text information; dropping it
///    removes colour-cast noise.
/// 2. normalize — stretches the histogram (autocontrast), so a
///    shadowed page and a bright page both get full black/white range.
/// 3. sharpen — a mild 3x3 sharpen kernel, so small marks (the `*`
///    answer marker, option letters) keep their edges after the
///    contrast stretch.
///
/// Measured on the real DATA ENTRY OPERATOR camera photo
/// (19 Nov 2026, tesseract.js PSM 3): raw = 7 of 21 asterisks read,
/// grayscale + autocontrast + sharpen = 9 of 21. Preprocessing helps
/// but does NOT fix the asterisk for Tesseract — the `*` is a tiny
/// mark that Tesseract still misreads as `§` / `"` / `®` or drops.
/// The reliable camera-photo route is the Gemini "best quality" tier
/// (21/21 asterisks on the same photo); ML Kit is the default tier.
/// This helper is therefore applied ONLY to the Tesseract tier, and
/// the caller keeps whichever OCR text has more words — a worse
/// Tesseract read can never replace a better ML Kit read.
///
/// Never throws and never corrupts: any failure (undecodable bytes,
/// too small to sharpen) returns the input bytes unchanged. No
/// upscaling: 2x upscaling was measured WORSE for the asterisk
/// (6/21) and doubles the bytes. No deskew: a perspective/curvature
/// correction needs a document-edge detector, which is out of scope —
/// ML Kit and Gemini both tolerate mild skew already.
Uint8List preprocessForOcr(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    // A 1x1 or degenerate image has nothing to enhance.
    if (decoded.width < 8 || decoded.height < 8) return bytes;
    var out = img.grayscale(decoded);
    out = img.normalize(out, min: 0, max: 255);
    out = img.convolution(
      out,
      filter: const [0, -1, 0, -1, 5, -1, 0, -1, 0],
    );
    return img.encodeJpg(out, quality: 92);
  } catch (_) {
    return bytes;
  }
}
