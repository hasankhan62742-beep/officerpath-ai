import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/book_selection.dart';
import '../services/book_structure.dart';
import '../widgets/developer_credit_footer.dart';

/// Selection screen (v1.2): after upload analysis, before the book is
/// saved — and again when generating a test from an already-saved
/// book ("Is book ke kis hisse se test banayein?").
///
/// Shows the detected parts as a checklist (title + pages + MCQ
/// count), a custom page-range picker, and a "Poori book" select-all.
/// Returns the [BookSelection] via `Navigator.pop`, or null when the
/// user cancels.
///
/// When the book has no detected parts (no headings), only the
/// page-range picker is shown, with an honest note saying so.
class BookSelectionScreen extends StatefulWidget {
  const BookSelectionScreen({
    super.key,
    required this.parts,
    required this.totalPages,
    this.initial,
    this.title = 'Kis hisse se test banayein?',
  });

  /// Detected parts with exact question counts (empty = no headings).
  final List<BookPart> parts;

  /// Total PDF pages (0 when unknown — TXT / pasted text).
  final int totalPages;

  final BookSelection? initial;

  /// "Kis hisse se test banayein?" (test time) vs "Kis hisse save
  /// karein?" (upload time).
  final String title;

  @override
  State<BookSelectionScreen> createState() => _BookSelectionScreenState();
}

class _BookSelectionScreenState extends State<BookSelectionScreen> {
  late Set<String> _selectedParts;
  final _fromController = TextEditingController();
  final _toController = TextEditingController();
  bool _useRange = false;

  @override
  void initState() {
    super.initState();
    _selectedParts = Set.of(widget.initial?.partTitles ?? {});
    final initial = widget.initial;
    if (initial?.fromPage != null && initial?.toPage != null) {
      _useRange = true;
      _fromController.text = initial!.fromPage.toString();
      _toController.text = initial.toPage.toString();
    }
  }

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  int get _totalQuestions =>
      widget.parts.fold(0, (sum, p) => sum + p.questionCount);

  int get _selectedCount {
    if (_selectedParts.isEmpty && !_useRange) return _totalQuestions;
    var count = 0;
    for (final p in widget.parts) {
      if (_selectedParts.isEmpty || _selectedParts.contains(p.title)) {
        count += p.questionCount;
      }
    }
    return count;
  }

  void _save() {
    int? from;
    int? to;
    if (_useRange) {
      from = int.tryParse(_fromController.text.trim());
      to = int.tryParse(_toController.text.trim());
      if (from == null || to == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Page range mein dono numbers likhein.'),
          ),
        );
        return;
      }
    }
    final selection = BookSelection(
      partTitles: _selectedParts,
      fromPage: from,
      toPage: to,
    ).normalised(widget.totalPages);
    Navigator.pop(context, selection);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: theme.colorScheme.primaryContainer,
            child: ListTile(
              leading: const Icon(Icons.checklist),
              title: Text(
                _selectedParts.isEmpty && !_useRange
                    ? 'Poori book — $_totalQuestions MCQs'
                    : 'Selected: $_selectedCount MCQs',
              ),
              subtitle: const Text(
                'Test sirf selected hisse se banega. Kuch select na '
                'karein to poori book use hogi.',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () {
                    setState(() {
                      _selectedParts.clear();
                      _useRange = false;
                    });
                  },
                  icon: const Icon(Icons.select_all),
                  label: const Text('Poori book'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _selectedParts = widget.parts
                          .map((p) => p.title)
                          .toSet();
                    });
                  },
                  child: const Text('Sab hisse'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (widget.parts.isEmpty) ...[
            const Card(
              child: ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('Is book mein headings nahi mileen'),
                subtitle: Text(
                  'Structure detection headings se hoti hai — is book '
                  'mein koi title/heading nahi mila, is liye sirf page '
                  'range se chunna ja sakta hai.',
                ),
              ),
            ),
          ] else ...[
            Text(
              'Hisse (parts)',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            ...widget.parts.map(
              (p) => CheckboxListTile(
                value: _selectedParts.contains(p.title),
                onChanged: (v) {
                  setState(() {
                    if (v == true) {
                      _selectedParts.add(p.title);
                    } else {
                      _selectedParts.remove(p.title);
                    }
                  });
                },
                title: Text(p.title),
                subtitle: Text(
                  'Pages ${p.startPage}–${p.endPage} • '
                  '${p.questionCount} MCQs'
                  '${p.pendingCount > 0 ? ' • ${p.pendingCount} pending' : ''}',
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (widget.totalPages > 1) ...[
            Text(
              'Ya page range chunein',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              value: _useRange,
              onChanged: (v) => setState(() => _useRange = v),
              title: const Text('Page range use karein'),
              subtitle: Text(
                'PDF page numbers se (1–${widget.totalPages}).',
              ),
            ),
            if (_useRange)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _fromController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: const InputDecoration(
                        labelText: 'From page',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _toController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: const InputDecoration(
                        labelText: 'To page',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Save selection', style: TextStyle(fontSize: 16)),
            ),
          ),
          const DeveloperCreditFooter(),
        ],
      ),
    );
  }
}
