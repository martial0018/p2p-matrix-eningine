(() => {
  let client = null;
  let userId = null;
  let saveTimer = null;
  let pollTimer = null;
  let controlSub = null;
  let sharedDataSub = null;
  let lastFingerprint = '';
  const knownEvents = new Set();
  let errorShown = false;
  let controlTimer = null;
  let applyingSharedControl = false;
  let lastSharedControl = null;
  let controlRevision = 0;
  let controlSavePending = 0;
  let controlSaveQueue = Promise.resolve();
  let lastPauseEnforcementAt = 0;
  const persistedSellerMatches = new Set();

  const snapshotState = () => JSON.parse(JSON.stringify(S, (key, value) => {
    if (key === 'timer' || key === 'audioCtx') return undefined;
    return value;
  }));

  const fingerprintState = (state) => JSON.stringify(state);
  const eventKey = (entry) => `${entry.day}:${entry.type}:${entry.message}`;

  function backendIsAvailable() {
    return Boolean(client) && window.MATRIX_BACKEND_AVAILABLE !== false;
  }

  function isExpectedBackendIssue(error) {
    const message = String(error?.message || error || '');
    const code = String(error?.code || error?.status || '');
    return [
      '42P01', 'PGRST301', 'PGRST116', '404'
    ].includes(code) || /schema cache|does not exist|missing relation|not found|timed out|RESTRICT/i.test(message);
  }

  function isPermissionIssue(error) {
    const message = String(error?.message || error || '');
    const code = String(error?.code || error?.status || '');
    return ['42501', '401', '403'].includes(code) ||
      /row-level security|permission denied|not authorized|unauthorized/i.test(message);
  }

  async function loadProfileNames(ownerIds) {
    const role = String(document.documentElement.dataset.authRole || '').toLowerCase();
    const isAdmin = role === 'admin';
    const ids = [...new Set(ownerIds.filter((id) => id && (isAdmin || id === userId)))];
    if (!ids.length) return new Map();
    const { data, error } = await client.from('profiles').select('id, display_name').in('id', ids);
    if (error) {
      console.warn('Could not resolve database display names:', error);
      return new Map();
    }
    return new Map((data || []).map((profile) => [profile.id, profile.display_name]));
  }

  function notifyBackendError(error) {
    if (!error) return;
    const expected = isExpectedBackendIssue(error);
    const permissionIssue = isPermissionIssue(error);
    if (expected || permissionIssue) {
      window.MATRIX_BACKEND_AVAILABLE = false;
    }
    if (errorShown) return;
    errorShown = true;
    console.error('Matrix backend error:', error);
    if (typeof toast !== 'function') return;
    if (permissionIssue) {
      toast(
        'Supabase permission denied',
        'The database rejected a request. Run the latest Supabase migration, then reload and sign in again.',
        'err'
      );
    } else if (expected) {
      toast(
        'Supabase setup incomplete',
        'A required database table or function is missing. Run the project schema and migration, then reload.',
        'err'
      );
    } else {
      toast('Backend unavailable', 'The dashboard will continue in local-only mode. Check the browser console for details.', 'err');
    }
  }

  async function loadSnapshot() {
    if (!backendIsAvailable()) return;
    const { data, error } = await client
      .from('simulation_snapshots')
      .select('state')
      .eq('user_id', userId)
      .maybeSingle();
    if (error) throw error;
    if (!data || !data.state || typeof data.state !== 'object') return;

    const saved = data.state;
    Object.keys(saved).forEach((key) => {
      if (key !== 'timer' && key !== 'audioCtx' && key in S) S[key] = saved[key];
    });
    S.playing = false;
    S.timer = null;
    if (typeof renderAll === 'function') renderAll();
    if (typeof updateMaturityPreview === 'function') updateMaturityPreview();
    if (typeof updateLiveDepth === 'function') updateLiveDepth();
  }

  async function loadSharedOrders() {
    if (!backendIsAvailable()) return;
    let query = client.from('simulation_orders')
      .select('id, owner_id, order_data, updated_at')
      .order('updated_at', { ascending: false });

    const { data, error } = await query;
    if (error) throw error;
    const rows = data || [];
    const profileNames = await loadProfileNames(rows.flatMap((row) => [
      row.owner_id,
      ...(row.order_data.databaseCounterparties || []).map((counterparty) => counterparty.owner_id)
    ]));
    S.orders = Array.isArray(data)
      ? rows.map((row) => ({
        ...row.order_data,
        buyer_name: profileNames.get(row.owner_id) || row.order_data.buyer_name,
        databaseCounterparties: (row.order_data.databaseCounterparties || []).map((counterparty) => ({
          ...counterparty,
          name: profileNames.get(counterparty.owner_id) || counterparty.name
        })),
        id: row.id,
        owner_id: row.owner_id
      }))
      : [];
    if (typeof renderAll === 'function') renderAll();
    if (typeof render === 'function') render();
    if (typeof renderOrders === 'function') renderOrders();
  }

  async function saveSharedOrders() {
    if (!backendIsAvailable()) return;
    const role = String(document.documentElement.dataset.authRole || '').toLowerCase();
    const isAdmin = role === 'admin';
    const rows = (S.orders || [])
      .filter((order) => order.owner_id && (isAdmin || order.owner_id === userId))
      .map((order) => ({
        id: order.id,
        owner_id: order.owner_id,
        order_data: order,
        updated_at: new Date().toISOString()
      }));
    if (!rows.length) return;
    const { error } = await client.from('simulation_orders').upsert(rows);
    if (error) throw error;
  }

  async function loadSharedQueue() {
    if (!backendIsAvailable()) return;
    let query = client.from('simulation_queue')
      .select('id, owner_id, queue_data, updated_at')
      .order('updated_at', { ascending: false });

    const { data, error } = await query;
    if (error) throw error;
    const rows = data || [];
    const profileNames = await loadProfileNames(rows.flatMap((row) => [row.owner_id, row.queue_data?.matchedBuyerOwnerId]));
    S.queue = Array.isArray(data)
      ? rows
        .filter((row) => !['Q-101', 'Q-102'].includes(row.id)
          && !/^Q-S\d+$/.test(row.id)
          && !/^Queued Agent \d+$/.test(row.queue_data?.name || ''))
        .map((row) => ({
          ...row.queue_data,
          name: profileNames.get(row.owner_id) || row.queue_data.name,
          matchedBuyerName: profileNames.get(row.queue_data?.matchedBuyerOwnerId) || row.queue_data.matchedBuyerName,
          id: row.id,
          owner_id: row.owner_id
        }))
      : [];
    if (typeof renderAll === 'function') renderAll();
    if (typeof render === 'function') render();
    if (typeof renderQueue === 'function') renderQueue();
  }

  async function saveSharedQueue() {
    if (!backendIsAvailable()) return;
    const role = String(document.documentElement.dataset.authRole || '').toLowerCase();
    const isAdmin = role === 'admin';
    const rows = (S.queue || [])
      .filter((entry) => entry.owner_id && (isAdmin || entry.owner_id === userId))
      .map((entry) => ({
        id: entry.id,
        owner_id: entry.owner_id,
        queue_data: entry,
        updated_at: new Date().toISOString()
      }));
    if (!rows.length) return;
    const { error } = await client.from('simulation_queue').upsert(rows);
    if (error) throw error;
  }

  async function saveMatchedSellerEntries() {
    if (!backendIsAvailable() || !userId) return;
    const role = String(document.documentElement.dataset.authRole || '').toLowerCase();
    if (role === 'admin') return;

    const buyerOrders = (S.orders || []).filter(order =>
      order.owner_id === userId && ['PAIRED', 'PARTIAL', 'PROOF', 'FLAGGED'].includes(order.status)
    );
    for (const order of buyerOrders) {
      const orderLegs = order.legs || [];
      const matchedIds = new Set([
        ...orderLegs.map(leg => leg.id),
        order.matchObj?.id
      ].filter(Boolean));
      for (const entry of S.queue || []) {
        if (!matchedIds.has(entry.id) || !entry.owner_id || entry.owner_id === userId) continue;
        const linkedOrderId = entry.matchedBuyerOrderId || entry.matchedOrderId;
        if (entry.status === 'WAITING' || (entry.status === 'MATCHED' && (!linkedOrderId || linkedOrderId === order.id))) {
          entry.status = 'MATCHED';
          entry.matchedOrderId = order.id;
          entry.matchedBuyerOrderId = order.id;
          entry.matchedBuyerOwnerId = userId;
          entry.matchedBuyerName = order.buyer_name || order.buyerName || 'Buyer';
          const leg = orderLegs.find(item => item.id === entry.id);
          entry.matchedAmount = Number(leg?.fill) || Math.min(
            Number(entry.amount) || 0,
            Number(order.transferAmt || order.principal) || 0
          );
        }
      }
    }

    for (const order of buyerOrders) {
      const databaseSellerIds = new Set([
        ...(order.databaseCounterparties || []).map(counterparty => counterparty.order_id),
        ...(S.queue || [])
          .filter(entry => entry.owner_id && entry.owner_id !== userId)
          .map(entry => entry.id)
      ].filter(Boolean));
      for (const leg of order.legs || []) {
        if (!leg.id || leg.id === 'TREASURY' || !databaseSellerIds.has(leg.id)) continue;
        const matchKey = `${leg.id}:${order.id}`;
        if (persistedSellerMatches.has(matchKey)) continue;
        const { error } = await client.rpc('buyer_match_simulation_queue_entry', {
          p_order_id: order.id,
          p_queue_id: leg.id
        });
        if (error) throw error;
        persistedSellerMatches.add(matchKey);
      }
    }
  }

  function hasPendingSellerMatchLinks() {
    if (!userId || String(document.documentElement.dataset.authRole || '').toLowerCase() === 'admin') return false;
    return (S.orders || []).some(order => {
      if (order.owner_id !== userId || !['PAIRED', 'PARTIAL', 'PROOF', 'FLAGGED'].includes(order.status)) return false;
      const matchedIds = new Set([
        ...(order.legs || []).map(leg => leg.id),
        order.matchObj?.id
      ].filter(Boolean));
      return (S.queue || []).some(entry =>
        matchedIds.has(entry.id) &&
        entry.owner_id &&
        entry.owner_id !== userId &&
        (entry.status === 'WAITING' ||
          (entry.status === 'MATCHED' &&
            (!entry.matchedBuyerOrderId && !entry.matchedOrderId ||
             (entry.matchedBuyerOrderId || entry.matchedOrderId) === order.id)))
      );
    });
  }

  async function saveSnapshot(force = false) {
    if (!backendIsAvailable() || !userId) return;
    const state = snapshotState();
    const fingerprint = fingerprintState(state);
    if (!force && fingerprint === lastFingerprint) return;

    await saveSharedOrders();
    await saveMatchedSellerEntries();
    await saveSharedQueue();
    const { error } = await client.from('simulation_snapshots').upsert({
      user_id: userId,
      state,
      updated_at: new Date().toISOString()
    });
    if (error) throw error;
    lastFingerprint = fingerprint;

    const events = (S.logs || [])
      .filter((entry) => !knownEvents.has(eventKey(entry)))
      .slice(0, 20)
      .map((entry) => ({
        user_id: userId,
        day: Number(entry.day) || 0,
        event_type: String(entry.type || 'SYSTEM'),
        message: String(entry.message || ''),
        payload: {}
      }));
    if (events.length) {
      const result = await client.from('simulation_events').insert(events);
      if (result.error) throw result.error;
      (S.logs || []).forEach((entry) => knownEvents.add(eventKey(entry)));
    }
  }

  function scheduleSave(force = false) {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => saveSnapshot(force).catch(notifyBackendError), 700);
  }

  function applySharedControl(control) {
    if (controlSavePending || !control || typeof window.applyLocalEngineState !== 'function') return;
    const pauseOverride = window.isMatrixEnginePauseOverrideActive?.() === true;
    const serverPlaying = Boolean(control.playing);
    const next = {
      playing: serverPlaying && !pauseOverride,
      speed: Number(control.speed) || 1200,
      day: Number.isFinite(Number(control.day)) ? Number(control.day) : 0
    };
    if (pauseOverride && serverPlaying && Date.now() - lastPauseEnforcementAt >= 5000) {
      lastPauseEnforcementAt = Date.now();
      saveSharedControl(false, next.speed, next.day).catch(notifyBackendError);
    }
    if (
      lastSharedControl &&
      lastSharedControl.playing === next.playing &&
      lastSharedControl.speed === next.speed &&
      lastSharedControl.day === next.day
    ) return;
    lastSharedControl = next;
    applyingSharedControl = true;
    window.applyLocalEngineState(next.playing, next.speed, next.day);
    applyingSharedControl = false;
  }

  async function loadSharedControl() {
    if (!backendIsAvailable()) return;
    const revision = controlRevision;
    const { data, error } = await client.from('simulation_control').select('playing, speed, day').eq('id', true).maybeSingle();
    if (error) throw error;
    if (revision !== controlRevision || controlSavePending) return;
    applySharedControl(data);
  }

  async function saveSharedControl(playing, speed, day) {
    if (!backendIsAvailable() || !userId || document.documentElement.dataset.authRole !== 'admin') return;
    const revision = ++controlRevision;
    const next = {
      playing: Boolean(playing),
      speed: Number(speed) || 1200,
      day: Number.isFinite(Number(day)) ? Number(day) : 0
    };
    controlSavePending += 1;
    const save = controlSaveQueue.then(async () => {
      const { error } = await client.from('simulation_control').upsert({
        id: true,
        ...next,
        updated_by: userId,
        updated_at: new Date().toISOString()
      });
      if (error) throw error;
      if (revision === controlRevision) lastSharedControl = next;
    });
    controlSaveQueue = save.catch(() => {});
    try {
      await save;
    } finally {
      controlSavePending -= 1;
    }
  }

  async function refreshSharedData() {
    await Promise.all([
      loadSharedOrders().catch(notifyBackendError),
      loadSharedQueue().catch(notifyBackendError)
    ]);
    if (window.reconcileMatchedQueueEntries?.()) scheduleSave(true);
  }

  function subscribeToSharedControl() {
    if (!client || controlSub) return;
    controlSub = client.channel('simulation-control-sync')
      .on('postgres_changes', {
        event: '*',
        schema: 'public',
        table: 'simulation_control'
      }, (payload) => {
        if (payload?.new) {
          applySharedControl(payload.new);
        }
      })
      .subscribe();
  }

  function subscribeToSharedData() {
    if (!client || sharedDataSub) return;
    sharedDataSub = client.channel('matrix-shared-data-sync')
      .on('postgres_changes', {
        event: '*',
        schema: 'public',
        table: 'simulation_orders'
      }, () => refreshSharedData())
      .on('postgres_changes', {
        event: '*',
        schema: 'public',
        table: 'simulation_queue'
      }, () => refreshSharedData())
      .subscribe();
  }

  async function start(detail) {
    client = detail.client;
    userId = detail.session.user.id;
    persistedSellerMatches.clear();
    window.MATRIX_BACKEND_AVAILABLE = true;
    errorShown = false;
    try {
      await loadSnapshot();
      S.user.name = detail.profile?.display_name || detail.session.user.email || 'User';
      await loadSharedOrders().catch(notifyBackendError);
      if (window.MATRIX_BACKEND_AVAILABLE === false) return;
      await loadSharedQueue().catch(notifyBackendError);
      if (window.MATRIX_BACKEND_AVAILABLE === false) return;
      const normalizedOrders = window.normalizeMatchedBuyerOrders?.() || false;
      const reconciledMatches = window.reconcileMatchedQueueEntries?.() || false;
      await loadSharedControl().catch(notifyBackendError);
      if (window.MATRIX_BACKEND_AVAILABLE === false) return;
      subscribeToSharedControl();
      subscribeToSharedData();
      (S.logs || []).forEach((entry) => knownEvents.add(eventKey(entry)));
      lastFingerprint = fingerprintState(snapshotState());
      if (normalizedOrders || reconciledMatches || hasPendingSellerMatchLinks()) scheduleSave(true);
      pollTimer = setInterval(() => {
        const current = fingerprintState(snapshotState());
        if (current !== lastFingerprint) scheduleSave();
      }, 1500);
      controlTimer = setInterval(() => {
        if (backendIsAvailable()) {
          loadSharedControl().catch(notifyBackendError);
        }
      }, 1500);
    } catch (error) {
      notifyBackendError(error);
    }
  }

  function stop() {
    clearTimeout(saveTimer);
    clearInterval(pollTimer);
    clearInterval(controlTimer);
    if (controlSub) {
      client?.removeChannel(controlSub);
      controlSub = null;
    }
    if (sharedDataSub) {
      client?.removeChannel(sharedDataSub);
      sharedDataSub = null;
    }
    saveTimer = null;
    pollTimer = null;
    client = null;
    userId = null;
    window.MATRIX_BACKEND_AVAILABLE = false;
    lastFingerprint = '';
    lastSharedControl = null;
    persistedSellerMatches.clear();
    knownEvents.clear();
  }

  window.addEventListener('matrix:authenticated', (event) => start(event.detail));
  window.addEventListener('matrix:profile-updated', (event) => {
    if (!S.user || !event.detail?.display_name) return;
    S.user.name = event.detail.display_name;
    scheduleSave(true);
  });
  window.addEventListener('matrix:persist', () => scheduleSave());
  window.addEventListener('matrix:refresh-shared-data', () => refreshSharedData());
  window.addEventListener('matrix:engine-control', (event) => {
    if (!applyingSharedControl && event.detail.persist === true) {
      saveSharedControl(event.detail.playing, event.detail.speed, event.detail.day).catch(notifyBackendError);
    }
  });
  window.addEventListener('pagehide', () => {
    if (client && userId) saveSnapshot().catch(notifyBackendError);
  });
  window.addEventListener('matrix:signed-out', stop);
})();
