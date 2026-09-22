(() => {
  let client = null;
  let userId = null;
  let saveTimer = null;
  let pollTimer = null;
  let lastFingerprint = '';
  const knownEvents = new Set();
  let errorShown = false;

  const snapshotState = () => JSON.parse(JSON.stringify(S, (key, value) => {
    if (key === 'timer' || key === 'audioCtx') return undefined;
    return value;
  }));

  const fingerprintState = (state) => JSON.stringify(state);
  const eventKey = (entry) => `${entry.day}:${entry.type}:${entry.message}`;

  function notifyBackendError(error) {
    if (errorShown) return;
    errorShown = true;
    console.error('Matrix backend error:', error);
    if (typeof toast === 'function') toast('Backend unavailable', 'Run the Supabase schema before using persistence.', 'err');
  }

  async function loadSnapshot() {
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

  async function saveSnapshot() {
    if (!client || !userId) return;
    const state = snapshotState();
    const fingerprint = fingerprintState(state);
    if (fingerprint === lastFingerprint) return;

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

  function scheduleSave() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => saveSnapshot().catch(notifyBackendError), 700);
  }

  async function start(detail) {
    client = detail.client;
    userId = detail.session.user.id;
    errorShown = false;
    try {
      await loadSnapshot();
      (S.logs || []).forEach((entry) => knownEvents.add(eventKey(entry)));
      lastFingerprint = fingerprintState(snapshotState());
      pollTimer = setInterval(() => {
        const current = fingerprintState(snapshotState());
        if (current !== lastFingerprint) scheduleSave();
      }, 1500);
    } catch (error) {
      notifyBackendError(error);
    }
  }

  function stop() {
    clearTimeout(saveTimer);
    clearInterval(pollTimer);
    saveTimer = null;
    pollTimer = null;
    client = null;
    userId = null;
    lastFingerprint = '';
    knownEvents.clear();
  }

  window.addEventListener('matrix:authenticated', (event) => start(event.detail));
  window.addEventListener('pagehide', () => {
    if (client && userId) saveSnapshot().catch(notifyBackendError);
  });
  window.addEventListener('matrix:signed-out', stop);
})();
