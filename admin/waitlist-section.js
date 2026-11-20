/* ============================================================
 * OfficerPath AI — Admin panel: Waitlist section (SNIPPET).
 * DO NOT load this file as its own <script>. It is a fragment to
 * paste INSIDE the IIFE in admin/app.js — see docs/waitlist.md for
 * the exact anchor points (wire-up in boot(), a loadWaitlist() call
 * in loadAll(), and these functions pasted before the codes-table
 * section). It reuses the helpers already in app.js: $, esc,
 * fmtDate, toast, and the `client` Supabase client. No credentials
 * in this file.
 *
 * ADMIN GATE: loadWaitlist() is only ever called from loadAll(),
 * which is only called after checkAdmin() has confirmed
 * profiles.is_admin — and the server enforces the same rule with
 * Row Level Security (005_waitlist.sql: only admins may SELECT).
 * ============================================================ */

var waitlistCache = []; // Last loaded waitlist rows, for search + CSV.

function loadWaitlist() {
  if (!adminUser) return;
  client.from('waitlist')
    .select('email, created_at, source')
    .order('created_at', { ascending: false })
    .limit(5000)
    .then(function (res) {
      if (res.error) throw res.error;
      waitlistCache = res.data || [];
      $('waitlist-count').textContent = waitlistCache.length;
      renderWaitlist();
    })
    .catch(function (e) {
      var el = $('waitlist-error');
      el.textContent = 'Could not load waitlist: ' + e.message;
      el.classList.remove('hidden');
    });
}

function renderWaitlist() {
  var q = ($('waitlist-search').value || '').trim().toLowerCase();
  var rows = waitlistCache.filter(function (w) {
    if (!q) return true;
    return (w.email || '').toLowerCase().indexOf(q) !== -1 ||
      (w.source || '').toLowerCase().indexOf(q) !== -1;
  });
  var tbody = $('waitlist-tbody');
  tbody.innerHTML = '';
  $('waitlist-empty').classList.toggle('hidden', rows.length !== 0);
  rows.forEach(function (w) {
    var tr = document.createElement('tr');
    tr.innerHTML =
      '<td>' + esc(w.email || '—') + '</td>' +
      '<td>' + fmtDate(w.created_at) + '</td>' +
      '<td>' + esc(w.source || '—') + '</td>';
    tbody.appendChild(tr);
  });
}

/* Export CSV — builds the file in the browser from the loaded rows.
 * No server call is needed. Use it at v2 launch to email the list
 * from hello@abdulqadeerml.com (see docs/waitlist.md). */
function exportWaitlistCsv() {
  if (!waitlistCache.length) {
    toast('Waitlist is empty — nothing to export.');
    return;
  }
  var lines = ['email,created_at,source'];
  waitlistCache.forEach(function (w) {
    lines.push([w.email, w.created_at, w.source].map(function (v) {
      return '"' + String(v == null ? '' : v).replace(/"/g, '""') + '"';
    }).join(','));
  });
  var blob = new Blob([lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
  var url = URL.createObjectURL(blob);
  var a = document.createElement('a');
  a.href = url;
  a.download = 'officerpath-waitlist.csv';
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
  toast('Exported ' + waitlistCache.length + ' waitlist email(s).');
}
