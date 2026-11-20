# OfficerPath AI — R8 / ProGuard rules for the release build.
#
# ML Kit text recognition (google_mlkit_text_recognition) references
# optional script recognizers — Chinese, Devanagari, Japanese, Korean —
# that the app never uses: only the Latin recognizer is bundled, and
# only it is ever instantiated (see lib/services/urdu_ocr.dart).
# R8 treats those absent classes as errors and fails the release build
# (minifyReleaseWithR8), so silence the warnings for them. This does
# NOT keep anything: the classes simply do not exist in the APK, and
# nothing at runtime can reach them.
-dontwarn com.google.mlkit.vision.text.**
