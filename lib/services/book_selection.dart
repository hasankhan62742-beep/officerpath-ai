import '../models/question.dart';
import 'book_structure.dart';

/// What the user picked on the selection screen (v1.2): one or more
/// book parts and/or a custom page range. The test-generation pool is
/// then ONLY the questions from the selection.
///
/// Honest limits: structure detection is heading-based, so a book
/// with no titles shows only the page-range picker; page ranges are
/// by PDF page numbers.
class BookSelection {
  const BookSelection({
    this.partTitles = const {},
    this.fromPage,
    this.toPage,
  });

  /// Parts the user ticked (by [BookPart.title]). Empty = no part
  /// filter (whole book, unless a page range is set).
  final Set<String> partTitles;

  /// Custom page range (1-based, inclusive). Null = no range filter.
  final int? fromPage;
  final int? toPage;

  bool get isWholeBook => partTitles.isEmpty && fromPage == null;

  /// Normalises a range: clamps to [1, totalPages] and swaps an
  /// inverted range instead of rejecting it.
  BookSelection normalised(int totalPages) {
    if (fromPage == null || toPage == null || totalPages <= 0) return this;
    var from = fromPage!.clamp(1, totalPages);
    var to = toPage!.clamp(1, totalPages);
    if (from > to) {
      final tmp = from;
      from = to;
      to = tmp;
    }
    return BookSelection(partTitles: partTitles, fromPage: from, toPage: to);
  }

  /// Filters [questions] to the selection. A question with page 0
  /// (unknown — TXT / pasted text) passes a part filter only when
  /// its part is ticked, and passes a page-range filter only when no
  /// range is set (its page cannot be verified).
  List<Question> apply(List<Question> questions) {
    return questions.where((q) {
      if (partTitles.isNotEmpty && !partTitles.contains(q.part)) {
        return false;
      }
      if (fromPage != null && toPage != null) {
        if (q.page == 0) return false;
        if (q.page < fromPage! || q.page > toPage!) return false;
      }
      return true;
    }).toList();
  }

  String describe() {
    if (isWholeBook) return 'Poori book';
    final bits = <String>[];
    if (partTitles.isNotEmpty) {
      bits.add(partTitles.length == 1
          ? partTitles.first
          : '${partTitles.length} hisse');
    }
    if (fromPage != null && toPage != null) {
      bits.add('pages $fromPage–$toPage');
    }
    return bits.join(' • ');
  }
}

/// One row of the selection screen: a detected part with its exact
/// question count and page span.
class PartRow {
  const PartRow({required this.part});

  final BookPart part;
}
