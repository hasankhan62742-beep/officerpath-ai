/* OfficerPath AI — Admin panel (static, no build step).
 *
 * Talks to Supabase with the ANON key only (from config.js) + Supabase
 * Auth. The admin login is email/password; after sign-in the panel
 * checks profiles.is_admin and refuses to render any data for
 * non-admins. All real enforcement lives in Row Level Security on the
 * server — this page is a second, client-side gate, not the security.
 *
 * NEVER put the secret admin key in this file or in config.js.
 * The plain activation code is shown exactly once (approval popup)
 * and never stored or displayed again — codes are listed by hash
 * prefix only.
 */
(function () {
  'use strict';

  var PLAN_LABELS = {
    premium_1month: 'Premium — 1 Month (Rs 600)',
    premium_2months: 'Premium — 2 Months (Rs 1,000)',
    premium_1year: 'Premium — 1 Year (Rs 5,000)',
    premium: 'Premium',
    free: 'Free',
  };

  var client = null; // Supabase client, created after config check.
  var adminUser = null; // Signed-in admin (Supabase Auth user).
  var usersCache = []; // Last loaded profiles, for search + detail.
  var testCountByUser = {}; // user_id -> tests taken.
  var currentDetailUserId = null;
  // transaction_id -> true for TIDs already spent on an APPROVED
  // payment (refreshed by loadPayments). The panel refuses approval
  // on those client-side; the issue-code function is the authority
  // and rejects them server-side too.
  var approvedTids = {};
  // Live payment-alert channel (Realtime). One subscription per login.
  var paymentChannel = null;
  // Web Audio context for the alert beep (created on first user
  // interaction — browsers block audio before any gesture).
  var alertAudioCtx = null;

  // Server error codes from issue-code, in the admin's words.
  var ISSUE_CODE_ERRORS = {
    tid_already_used: 'This transaction ID was already used on an approved payment.',
    payment_not_pending: 'This payment is no longer pending — it may already have been handled.',
    payment_not_found: 'This payment no longer exists.',
    payment_user_mismatch: 'This payment does not belong to that user.',
    payment_already_handled: 'This payment was already handled — no second code was issued.',
  };

  // Reads the Edge Function's JSON error body out of a
  // FunctionsHttpError: supabase-js puts the raw Response on
  // error.context and leaves the body unconsumed, so .json() works.
  // Falls back to the generic message when the body cannot be read.
  // Returns a Promise<string> already translated to admin wording.
  function serverErrorMessage(err) {
    var ctx = err && err.context;
    function translate(code) {
      return ISSUE_CODE_ERRORS[code] || code || err.message || 'Unknown error';
    }
    if (ctx && typeof ctx.json === 'function') {
      return ctx.json().then(function (body) {
        return translate(body && body.error);
      }).catch(function () {
        return err.message || 'Unknown error';
      });
    }
    if (ctx && ctx.error) return Promise.resolve(translate(ctx.error));
    return Promise.resolve(translate(err && err.message));
  }

  function $(id) { return document.getElementById(id); }

  function show(id) { var el = $(id); if (el) el.classList.remove('hidden'); }
  function hide(id) { var el = $(id); if (el) el.classList.add('hidden'); }

  function toast(message) {
    var el = $('toast');
    el.textContent = message;
    el.classList.remove('hidden');
    window.setTimeout(function () { el.classList.add('hidden'); }, 5000);
  }

  function esc(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function fmtDate(iso) {
    if (!iso) return '—';
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '—';
    return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
  }

  function planLabel(plan) { return PLAN_LABELS[plan] || plan || '—'; }

  /* ---------------- boot ---------------- */

  document.addEventListener('DOMContentLoaded', boot);

  function boot() {
    var cfg = window.OFFICERPATH_CONFIG;
    if (typeof supabase === 'undefined') {
      return showConfigError('The Supabase library (CDN) did not load. Check your connection and reload.');
    }
    if (!cfg || !cfg.SUPABASE_URL || !cfg.SUPABASE_ANON_KEY ||
        cfg.SUPABASE_URL.indexOf('YOUR-PROJECT') !== -1 ||
        cfg.SUPABASE_ANON_KEY.indexOf('YOUR-ANON') !== -1) {
      return showConfigError('config.js is missing or still has the placeholder values.');
    }
    try {
      client = supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);
    } catch (e) {
      return showConfigError('Could not create the Supabase client: ' + e.message);
    }

    $('login-form').addEventListener('submit', handleLogin);
    $('logout-btn').addEventListener('click', handleLogout);
    $('access-denied-back-btn').addEventListener('click', function () {
      showView('login');
    });
    $('users-search').addEventListener('input', renderUsers);
    $('user-detail-close').addEventListener('click', function () {
      hide('user-detail');
      currentDetailUserId = null;
    });
    $('revoke-premium-btn').addEventListener('click', revokePremium);
    $('approve-copy-btn').addEventListener('click', copyApproveCode);
    $('push-form').addEventListener('submit', sendPushNotification);
    $('waitlist-search').addEventListener('input', renderWaitlist);
    $('waitlist-export-btn').addEventListener('click', exportWaitlistCsv);
    $('push-type').addEventListener('change', function () {
      $('push-version-wrap').style.display =
        $('push-type').value === 'update_available' ? '' : 'none';
    });
    $('approve-close-btn').addEventListener('click', function () {
      hide('approve-modal');
      loadAll();
    });
    $('payment-alert-close').addEventListener('click', function () {
      hide('payment-alert-banner');
    });
    // Audio may only start after a user gesture: unlock (or resume)
    // the alert context on every tap/click.
    document.addEventListener('pointerdown', ensureAudio);

    // PWA: cache the panel shell so it opens when the connection
    // drops. Failure here is non-fatal — the panel still works online.
    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.register('/sw.js').catch(function () {});
    }

    // Restore an existing session (already signed in?).
    client.auth.getSession().then(function (res) {
      if (res.data && res.data.session && res.data.session.user) {
        checkAdmin(res.data.session.user);
      } else {
        showView('login');
      }
    }).catch(function () { showView('login'); });
  }

  function showConfigError(message) {
    $('config-error-text').textContent = message;
    show('config-error');
    hide('login-view');
  }

  function showView(name) {
    hide('login-view');
    hide('access-denied');
    hide('app-view');
    hide('config-error');
    if (name === 'login') {
      show('login-view');
      $('admin-info').classList.add('hidden');
    } else if (name === 'denied') {
      show('access-denied');
      $('admin-info').classList.add('hidden');
    } else if (name === 'app') {
      show('app-view');
      $('admin-info').classList.remove('hidden');
    }
  }

  /* ---------------- auth + admin gate ---------------- */

  function handleLogin(event) {
    event.preventDefault();
    var email = $('login-email').value.trim();
    var password = $('login-password').value;
    var errEl = $('login-error');
    errEl.classList.add('hidden');
    $('login-btn').disabled = true;
    client.auth.signInWithPassword({ email: email, password: password })
      .then(function (res) {
        $('login-btn').disabled = false;
        if (res.error) {
          errEl.textContent = 'Sign-in failed: ' + res.error.message;
          errEl.classList.remove('hidden');
          return;
        }
        checkAdmin(res.data.user);
      })
      .catch(function (e) {
        $('login-btn').disabled = false;
        errEl.textContent = 'Sign-in failed: ' + e.message;
        errEl.classList.remove('hidden');
      });
  }

  function handleLogout() {
    client.auth.signOut().then(function () {
      adminUser = null;
      showView('login');
    });
  }

  // The client-side admin gate: only profiles.is_admin may see data.
  // RLS on the server enforces the same rule — this is defence in depth.
  function checkAdmin(user) {
    client.from('profiles').select('is_admin').eq('id', user.id).maybeSingle()
      .then(function (res) {
        if (res.error || !res.data || res.data.is_admin !== true) {
          $('access-denied-email').textContent = user.email || user.id;
          client.auth.signOut();
          showView('denied');
          return;
        }
        adminUser = user;
        $('admin-email').textContent = user.email || user.id;
        showView('app');
        loadAll();
      })
      .catch(function () {
        $('access-denied-email').textContent = user.email || user.id;
        showView('denied');
      });
  }

  /* ---------------- loading ---------------- */

  function loadAll() {
    loadStats();
    loadSignups();
    loadUsers();
    loadPayments();
    loadCodes();
    loadPushHistory();
    loadWaitlist();
    subscribePaymentAlerts();
  }

  /* ---------------- live payment alerts (Realtime + sound) -------- */

  // Creates (or resumes) the Web Audio context. Browsers block audio
  // until a user gesture, so this is called on pointerdown and again
  // right before a beep. Never throws — sound is best-effort.
  function ensureAudio() {
    try {
      if (!alertAudioCtx) {
        var AC = window.AudioContext || window.webkitAudioContext;
        if (AC) alertAudioCtx = new AC();
      }
      if (alertAudioCtx && alertAudioCtx.state === 'suspended') {
        alertAudioCtx.resume();
      }
    } catch (e) { /* audio unavailable — the banner still shows */ }
  }

  // Short attention beep: three sine notes (A5, A5, D6), no audio
  // asset needed. Sound only works while the panel is open — a
  // closed web page cannot beep; the payment-alert email covers that.
  function playAlertSound() {
    try {
      ensureAudio();
      if (!alertAudioCtx) return;
      var t = alertAudioCtx.currentTime;
      [0, 0.25, 0.5].forEach(function (offset, i) {
        var osc = alertAudioCtx.createOscillator();
        var gain = alertAudioCtx.createGain();
        osc.type = 'sine';
        osc.frequency.value = i === 2 ? 1174.66 : 880;
        gain.gain.setValueAtTime(0.0001, t + offset);
        gain.gain.exponentialRampToValueAtTime(0.2, t + offset + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.0001, t + offset + 0.22);
        osc.connect(gain);
        gain.connect(alertAudioCtx.destination);
        osc.start(t + offset);
        osc.stop(t + offset + 0.25);
      });
    } catch (e) { /* sound is best-effort */ }
  }

  // Shows the gold banner for a new pending payment and beeps.
  function showPaymentAlert(p) {
    $('payment-alert-text').textContent =
      'New payment — ' + (p.email || '—') + ' — ' + planLabel(p.plan) +
      ' — TID ' + (p.transaction_id || '—');
    show('payment-alert-banner');
    playAlertSound();
  }

  // Subscribes once per login to INSERTs on public.payments
  // (status pending). Needs migration 014 (payments in the
  // supabase_realtime publication) applied live; until then the
  // subscription stays silent and nothing else breaks.
  function subscribePaymentAlerts() {
    if (!client || paymentChannel) return;
    paymentChannel = client
      .channel('officerpath-payments')
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'public',
          table: 'payments',
          filter: 'status=eq.pending',
        },
        function (payload) {
          var p = (payload && payload.new) || {};
          showPaymentAlert(p);
          loadPayments();
          loadStats();
        },
      )
      .subscribe();
  }

  function countQuery(table, filter) {
    var q = client.from(table).select('id', { count: 'exact', head: true });
    if (filter) q = filter(q);
    return q.then(function (res) {
      if (res.error) throw res.error;
      return res.count || 0;
    });
  }

  function loadStats() {
    Promise.all([
      countQuery('profiles'),
      countQuery('profiles', function (q) { return q.eq('plan', 'premium'); }),
      countQuery('payments', function (q) { return q.eq('status', 'pending'); }),
      countQuery('activation_codes'),
      countQuery('activation_codes', function (q) { return q.not('used_at', 'is', null); }),
      countQuery('test_results'),
    ]).then(function (counts) {
      $('stat-total-users').textContent = counts[0];
      $('stat-premium-users').textContent = counts[1];
      $('stat-pending-payments').textContent = counts[2];
      $('stat-codes-issued').textContent = counts[3];
      $('stat-codes-used').textContent = counts[4];
      $('stat-tests-taken').textContent = counts[5];
    }).catch(function (e) {
      var el = $('dashboard-error');
      el.textContent = 'Could not load dashboard numbers: ' + e.message;
      el.classList.remove('hidden');
    });
  }

  // Per-day signups for the last 30 days, plain HTML/CSS bars.
  function loadSignups() {
    var since = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
    client.from('profiles').select('created_at').gte('created_at', since).limit(5000)
      .then(function (res) {
        if (res.error) throw res.error;
        var perDay = {};
        (res.data || []).forEach(function (row) {
          var day = String(row.created_at).slice(0, 10);
          perDay[day] = (perDay[day] || 0) + 1;
        });
        var max = 1;
        var days = [];
        for (var i = 29; i >= 0; i--) {
          var d = new Date(Date.now() - i * 24 * 60 * 60 * 1000);
          var key = d.toISOString().slice(0, 10);
          var n = perDay[key] || 0;
          days.push({ key: key, n: n });
          if (n > max) max = n;
        }
        var chart = $('signup-chart');
        chart.innerHTML = '';
        days.forEach(function (day) {
          var bar = document.createElement('div');
          bar.className = 'chart-bar' + (day.n === 0 ? ' zero' : '');
          bar.style.height = Math.max(2, Math.round((day.n / max) * 100)) + '%';
          bar.title = day.key + ': ' + day.n + ' signup' + (day.n === 1 ? '' : 's');
          chart.appendChild(bar);
        });
      })
      .catch(function () {
        $('signup-chart').innerHTML = '<p class="muted">Could not load signup history.</p>';
      });
  }

  function loadUsers() {
    client.from('profiles')
      .select('id, username, email, plan, premium_until, created_at')
      .order('created_at', { ascending: false })
      .limit(200)
      .then(function (res) {
        if (res.error) throw res.error;
        usersCache = res.data || [];
        return client.from('test_results').select('user_id').limit(10000);
      })
      .then(function (res) {
        testCountByUser = {};
        (res.data || []).forEach(function (row) {
          var id = row.user_id;
          testCountByUser[id] = (testCountByUser[id] || 0) + 1;
        });
        renderUsers();
      })
      .catch(function (e) {
        $('users-tbody').innerHTML =
          '<tr><td colspan="6">Could not load users: ' + esc(e.message) + '</td></tr>';
      });
  }

  function renderUsers() {
    var q = ($('users-search').value || '').trim().toLowerCase();
    var rows = usersCache.filter(function (u) {
      if (!q) return true;
      return (u.email || '').toLowerCase().indexOf(q) !== -1 ||
        (u.username || '').toLowerCase().indexOf(q) !== -1;
    });
    var tbody = $('users-tbody');
    tbody.innerHTML = '';
    $('users-empty').classList.toggle('hidden', rows.length !== 0);
    rows.forEach(function (u) {
      var tr = document.createElement('tr');
      tr.dataset.userId = u.id;
      var premium = u.plan === 'premium';
      tr.innerHTML =
        '<td>' + esc(u.username || '—') + '</td>' +
        '<td>' + esc(u.email || '—') + '</td>' +
        '<td><span class="chip' + (premium ? ' premium' : '') + '">' + esc(premium ? 'Premium' : 'Free') + '</span></td>' +
        '<td>' + fmtDate(u.premium_until) + '</td>' +
        '<td>' + (testCountByUser[u.id] || 0) + '</td>' +
        '<td>' + fmtDate(u.created_at) + '</td>';
      tr.addEventListener('click', function () { openUser(u.id); });
      tbody.appendChild(tr);
    });
  }

  /* ---------------- user detail + revoke ---------------- */

  function openUser(userId) {
    currentDetailUserId = userId;
    var user = null;
    usersCache.forEach(function (u) { if (u.id === userId) user = u; });
    if (!user) return;
    $('user-detail-title').textContent =
      'User: ' + (user.username || user.email || userId);
    $('revoke-premium-btn').style.display =
      user.plan === 'premium' ? '' : 'none';
    $('user-detail-body').innerHTML = '<p class="muted">Loading…</p>';
    show('user-detail');
    $('user-detail').scrollIntoView({ behavior: 'smooth', block: 'start' });

    Promise.all([
      client.from('payments').select('plan, method, transaction_id, status, created_at')
        .eq('user_id', userId).order('created_at', { ascending: false }).limit(50),
      client.from('activation_codes').select('plan, months, issued_at, expires_at, used_at')
        .eq('user_id', userId).order('issued_at', { ascending: false }).limit(50),
      client.from('test_results').select('book_title, exam, score, total, created_at')
        .eq('user_id', userId).order('created_at', { ascending: false }).limit(50),
    ]).then(function (results) {
      var payments = (results[0].data || []);
      var codes = (results[1].data || []);
      var tests = (results[2].data || []);
      var html = '<p><strong>Email:</strong> ' + esc(user.email || '—') +
        ' &nbsp; <strong>Plan:</strong> ' + esc(planLabel(user.plan)) +
        ' &nbsp; <strong>Premium until:</strong> ' + fmtDate(user.premium_until) +
        ' &nbsp; <strong>Member since:</strong> ' + fmtDate(user.created_at) + '</p>';

      html += '<h3>Payments (' + payments.length + ')</h3>';
      html += payments.length === 0 ? '<p class="muted">No payments.</p>' :
        '<ul>' + payments.map(function (p) {
          return '<li>' + esc(planLabel(p.plan)) + ' — ' + esc(p.method) +
            ' — ' + esc(p.transaction_id) + ' — ' + esc(p.status) +
            ' (' + fmtDate(p.created_at) + ')</li>';
        }).join('') + '</ul>';

      html += '<h3>Codes (' + codes.length + ')</h3>';
      html += codes.length === 0 ? '<p class="muted">No codes issued.</p>' :
        '<ul>' + codes.map(function (c) {
          return '<li>' + esc(planLabel(c.plan)) + ' — issued ' + fmtDate(c.issued_at) +
            ', expires ' + fmtDate(c.expires_at) +
            (c.used_at ? ', used ' + fmtDate(c.used_at) : ', unused') + '</li>';
        }).join('') + '</ul>';

      html += '<h3>Test results (' + tests.length + ')</h3>';
      html += tests.length === 0 ? '<p class="muted">No tests taken.</p>' :
        '<ul>' + tests.map(function (t) {
          return '<li>' + esc(t.book_title || '—') + ' (' + esc(t.exam || '') + '): ' +
            esc(t.score) + '/' + esc(t.total) + ' — ' + fmtDate(t.created_at) + '</li>';
        }).join('') + '</ul>';

      $('user-detail-body').innerHTML = html;
    }).catch(function (e) {
      $('user-detail-body').innerHTML =
        '<p class="error-text">Could not load user detail: ' + esc(e.message) + '</p>';
    });
  }

  function revokePremium() {
    if (!currentDetailUserId) return;
    var user = null;
    usersCache.forEach(function (u) { if (u.id === currentDetailUserId) user = u; });
    var label = user ? (user.email || user.username || user.id) : currentDetailUserId;
    if (!window.confirm('Revoke Premium for ' + label + '?\n\nTheir plan becomes Free immediately. This cannot be undone except by issuing a new code.')) {
      return;
    }
    client.from('profiles')
      .update({ plan: 'free', premium_until: null })
      .eq('id', currentDetailUserId)
      .then(function (res) {
        if (res.error) throw res.error;
        toast('Premium revoked for ' + label + '.');
        hide('user-detail');
        currentDetailUserId = null;
        loadStats();
        loadUsers();
        loadCodes();
      })
      .catch(function (e) {
        toast('Could not revoke Premium: ' + e.message);
      });
  }

  /* ---------------- pending payments ---------------- */

  function loadPayments() {
    client.from('payments')
      .select('id, user_id, email, plan, method, transaction_id, status, created_at, screenshot_path')
      .eq('status', 'pending')
      .order('created_at', { ascending: false })
      .limit(100)
      .then(function (res) {
        if (res.error) throw res.error;
        var rows = res.data || [];
        // Second query: every payment's TID + status, so the queue can
        // flag a TID that was already used on another row (pending or
        // approved). Admins can read all payments (RLS), so this works.
        return client.from('payments')
          .select('transaction_id, status')
          .order('created_at', { ascending: false })
          .limit(1000)
          .then(function (allRes) {
            if (allRes.error) throw allRes.error;
            renderPayments(rows, allRes.data || []);
          });
      })
      .catch(function (e) {
        $('payments-tbody').innerHTML =
          '<tr><td colspan="6">Could not load payments: ' + esc(e.message) + '</td></tr>';
      });
  }

  function renderPayments(rows, allPayments) {
    // Counts per TID across ALL payments (not just pending).
    var tidCount = {};
    approvedTids = {};
    allPayments.forEach(function (p) {
      var tid = p.transaction_id;
      tidCount[tid] = (tidCount[tid] || 0) + 1;
      if (p.status === 'approved') approvedTids[tid] = true;
    });
    var tbody = $('payments-tbody');
    tbody.innerHTML = '';
    $('payments-empty').classList.toggle('hidden', rows.length !== 0);
    rows.forEach(function (p) {
      var tr = document.createElement('tr');
      var tidHtml = esc(p.transaction_id);
      var alreadyApproved = !!approvedTids[p.transaction_id];
      var duplicate = (tidCount[p.transaction_id] || 0) > 1;
      if (alreadyApproved) {
        tidHtml += ' <span style="color:#b91c1c;font-weight:700">\u26A0 TID ALREADY APPROVED</span>';
      } else if (duplicate) {
        tidHtml += ' <span style="color:#b91c1c;font-weight:700">\u26A0 DUPLICATE TID</span>';
      }
      tr.innerHTML =
        '<td>' + esc(p.email || '—') + '</td>' +
        '<td>' + esc(planLabel(p.plan)) + '</td>' +
        '<td>' + esc(p.method) + '</td>' +
        '<td>' + tidHtml + '</td>' +
        '<td>' + fmtDate(p.created_at) + '</td>' +
        '<td></td>';
      var approveBtn = document.createElement('button');
      approveBtn.textContent = 'Approve';
      if (alreadyApproved) {
        // Refuse approval in the UI too — the function rejects it
        // server-side as well, so a stale list cannot slip through.
        approveBtn.disabled = true;
        approveBtn.title = 'This transaction ID was already used on an approved payment.';
      } else {
        approveBtn.addEventListener('click', function () { approvePayment(p); });
      }
      var rejectBtn = document.createElement('button');
      rejectBtn.textContent = 'Reject';
      rejectBtn.style.marginLeft = '8px';
      rejectBtn.addEventListener('click', function () { rejectPayment(p); });
      tr.lastChild.appendChild(approveBtn);
      tr.lastChild.appendChild(rejectBtn);
      // Receipt screenshot (in-app upload) — signed URL, 1 hour.
      // The same receipt also arrives on WhatsApp; either channel
      // must be checked (TID + amount + receiver) before approving.
      if (p.screenshot_path) {
        var receiptBtn = document.createElement('button');
        receiptBtn.textContent = 'Receipt';
        receiptBtn.style.marginLeft = '8px';
        receiptBtn.addEventListener('click', function () {
          openReceipt(p.screenshot_path);
        });
        tr.lastChild.appendChild(receiptBtn);
      }
      tbody.appendChild(tr);
    });
  }

  // Opens a receipt screenshot via a 1-hour signed URL (the bucket is
  // private — no public link exists). Fails closed with a toast.
  function openReceipt(path) {
    client.storage.from('payment-proofs').createSignedUrl(path, 3600)
      .then(function (res) {
        if (res.error) throw res.error;
        window.open(res.data.signedUrl, '_blank');
      })
      .catch(function (e) {
        toast('Could not open receipt: ' + e.message);
      });
  }

  // Approve: the issue-code function checks the payment + TID and
  // marks the payment approved itself. The panel only passes
  // payment_id, shows the returned code ONCE, and refreshes. If the
  // function reports an error, NOTHING was marked — the admin sees
  // the reason and the queue reloads.
  function approvePayment(payment) {
    // Client-side refusal as well, in case the list is stale.
    if (approvedTids[payment.transaction_id]) {
      toast('This transaction ID was already used on an approved payment — approval refused.');
      loadPayments();
      return;
    }
    if (!window.confirm('Approve this payment and issue a code?\n\n' +
        (payment.email || '') + ' — ' + planLabel(payment.plan) + ' — ' +
        payment.method + ' ' + payment.transaction_id + '\n\n' +
        'Have you checked the receipt (Receipt link on this row and/or ' +
        'WhatsApp screenshot — TID + amount + receiver number)?')) {
      return;
    }
    client.functions.invoke('issue-code', {
      body: {
        user_id: payment.user_id,
        email: payment.email,
        plan: payment.plan,
        payment_id: payment.id,
      },
    }).then(function (res) {
      if (res.error) {
        return serverErrorMessage(res.error).then(function (msg) {
          throw new Error(msg);
        });
      }
      var data = res.data || {};
      if (!data.ok || !data.code) {
        throw new Error(
          ISSUE_CODE_ERRORS[data.error] ||
          data.error ||
          'The issue-code function did not return a code.',
        );
      }
      showApproveModal(payment, data.code);
      toast('Payment approved — code issued.');
      loadStats();
      loadPayments();
      loadCodes();
    }).catch(function (e) {
      toast('Could not approve payment: ' + e.message);
      loadPayments();
    });
  }

  function rejectPayment(payment) {
    // The v2 payments table has no column for a rejection reason, so
    // the reason is NOT stored — it is only shown here so the admin
    // can copy it into their message to the buyer.
    var reason = window.prompt(
      'Reject this payment? Optional reason (shown to you only, not stored):',
      '',
    );
    if (reason === null) return; // Cancelled.
    if (!window.confirm('Reject the payment from ' + (payment.email || '') + '?')) return;
    client.from('payments')
      .update({
        status: 'rejected',
        reviewed_by: adminUser ? adminUser.id : null,
        reviewed_at: new Date().toISOString(),
      })
      .eq('id', payment.id)
      .then(function (res) {
        if (res.error) throw res.error;
        toast('Payment rejected.' + (reason ? ' Reason to tell the buyer: ' + reason : ''));
        loadStats();
        loadPayments();
      })
      .catch(function (e) {
        toast('Could not reject payment: ' + e.message);
      });
  }

  function showApproveModal(payment, code) {
    var emailText =
      'Assalam-o-Alaikum!\n\n' +
      'Your OfficerPath AI Premium is now active.\n\n' +
      'Plan: ' + planLabel(payment.plan) + '\n' +
      'Activation code: ' + code + '\n\n' +
      'How to activate:\n' +
      '1. Open OfficerPath AI.\n' +
      '2. Tap UPGRADE, then go to "I have an activation code".\n' +
      '3. Enter the code above and tap Redeem.\n\n' +
      'The code is single-use and expires 7 days after it was issued.\n\n' +
      '— Qadeer Automations';
    $('approve-code').textContent = code;
    $('approve-email-text').value = emailText;
    var mailto = 'mailto:' + encodeURIComponent(payment.email || '') +
      '?subject=' + encodeURIComponent('Your OfficerPath AI Premium code') +
      '&body=' + encodeURIComponent(emailText);
    $('approve-mailto').setAttribute('href', mailto);
    show('approve-modal');
  }

  function copyApproveCode() {
    var code = $('approve-code').textContent;
    function done() { toast('Code copied.'); }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(code).then(done, function () { fallbackCopy(code); done(); });
    } else {
      fallbackCopy(code);
      done();
    }
  }

  function fallbackCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (e) { /* clipboard unavailable */ }
    document.body.removeChild(ta);
  }

  /* ---------------- push notifications ---------------- */

  // Sends via the send-notification Edge Function with the admin's
  // JWT. The function re-checks profiles.notifications_enabled
  // server-side — opted-out users are never sent to. The version
  // field is required only for "New version available" sends.
  function sendPushNotification(event) {
    event.preventDefault();
    var title = $('push-title').value.trim();
    var message = $('push-message').value.trim();
    var audience = $('push-audience').value;
    var type = $('push-type').value;
    var version = $('push-version').value.trim();
    var errEl = $('push-error');
    var resultEl = $('push-result');
    errEl.classList.add('hidden');
    resultEl.classList.add('hidden');
    if (!title || !message) {
      errEl.textContent = 'Title aur message dono lazmi hain.';
      errEl.classList.remove('hidden');
      return;
    }
    if (type === 'update_available' && !version) {
      errEl.textContent = 'New version ke liye version likhein (jaise 2.0.0).';
      errEl.classList.remove('hidden');
      return;
    }
    var audienceLabel = $('push-audience').selectedOptions[0].textContent;
    var typeLabel = $('push-type').selectedOptions[0].textContent;
    if (!window.confirm(
        'Send this notification?\n\n' + title + '\n' + message +
        '\n\nAudience: ' + audienceLabel + '\nType: ' + typeLabel +
        (type === 'update_available' ? '\nVersion: ' + version : '') +
        '\n\nSirf opted-in users jin ke paas app installed hai, un tak pahunchega.')) {
      return;
    }
    $('push-send-btn').disabled = true;
    client.functions.invoke('send-notification', {
      body: {
        title: title,
        body: message,
        audience: audience,
        type: type,
        version: type === 'update_available' ? version : undefined,
      },
    }).then(function (res) {
      $('push-send-btn').disabled = false;
      var data = res.data || {};
      if (!data.ok) {
        throw new Error(data.error || 'The send-notification function failed.');
      }
      resultEl.textContent = 'Sent to ' + data.recipient_count +
        ' user(s) (' + data.sent + ' delivered' +
        (data.failed ? ', ' + data.failed + ' failed' : '') + ').';
      resultEl.classList.remove('hidden');
      $('push-form').reset();
      $('push-version-wrap').style.display = '';
      toast('Notification sent to ' + data.recipient_count + ' user(s).');
      loadPushHistory();
    }).catch(function (e) {
      $('push-send-btn').disabled = false;
      errEl.textContent = 'Could not send notification: ' + e.message;
      errEl.classList.remove('hidden');
    });
  }

  function loadPushHistory() {
    client.from('sent_notifications')
      .select('title, audience, notification_type, version, sent_at, recipient_count')
      .order('sent_at', { ascending: false })
      .limit(50)
      .then(function (res) {
        if (res.error) throw res.error;
        var rows = res.data || [];
        var tbody = $('push-history-tbody');
        tbody.innerHTML = '';
        $('push-history-empty').classList.toggle('hidden', rows.length !== 0);
        rows.forEach(function (n) {
          var tr = document.createElement('tr');
          var typeLabel = n.notification_type === 'update_available'
            ? 'New version' + (n.version ? ' v' + n.version : '')
            : 'Announcement';
          tr.innerHTML =
            '<td>' + esc(n.title || '—') + '</td>' +
            '<td>' + esc(n.audience || '—') + '</td>' +
            '<td>' + esc(typeLabel) + '</td>' +
            '<td>' + fmtDate(n.sent_at) + '</td>' +
            '<td>' + esc(n.recipient_count) + '</td>';
          tbody.appendChild(tr);
        });
      })
      .catch(function (e) {
        $('push-history-tbody').innerHTML =
          '<tr><td colspan="5">Could not load sent history: ' + esc(e.message) + '</td></tr>';
      });
  }

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

  /* ---------------- codes table ---------------- */

  function loadCodes() {
    client.from('activation_codes')
      .select('id, code_hash, plan, months, user_id, issued_at, expires_at, used_at, used_by')
      .order('issued_at', { ascending: false })
      .limit(200)
      .then(function (res) {
        if (res.error) throw res.error;
        var codes = res.data || [];
        return client.from('profiles').select('id, email').limit(1000)
          .then(function (pres) {
            var emailById = {};
            (pres.data || []).forEach(function (p) { emailById[p.id] = p.email; });
            return { codes: codes, emailById: emailById };
          });
      })
      .then(function (bundle) {
        var tbody = $('codes-tbody');
        tbody.innerHTML = '';
        $('codes-empty').classList.toggle('hidden', bundle.codes.length !== 0);
        var now = new Date();
        bundle.codes.forEach(function (c) {
          var status = 'unused';
          var cls = '';
          if (c.used_at) { status = 'used'; cls = 'used'; }
          else if (c.expires_at && new Date(c.expires_at) < now) { status = 'expired'; cls = 'expired'; }
          var tr = document.createElement('tr');
          tr.innerHTML =
            '<td><code>' + esc(String(c.code_hash || '').slice(0, 12)) + '…</code></td>' +
            '<td>' + esc(planLabel(c.plan)) + '</td>' +
            '<td>' + esc(bundle.emailById[c.user_id] || '—') + '</td>' +
            '<td>' + fmtDate(c.issued_at) + '</td>' +
            '<td>' + fmtDate(c.expires_at) + '</td>' +
            '<td><span class="chip ' + cls + '">' + status + '</span></td>';
          tbody.appendChild(tr);
        });
      })
      .catch(function (e) {
        $('codes-tbody').innerHTML =
          '<tr><td colspan="6">Could not load codes: ' + esc(e.message) + '</td></tr>';
      });
  }
})();
