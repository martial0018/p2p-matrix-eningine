(() => {
  let client = null;
  let userId = null;
  let role = '';
  let displayName = 'You';
  let refreshTimer = null;
  const pendingLoads = new WeakSet();
  const loadedAt = new WeakMap();

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>"']/g, character => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    })[character]);
  }

  function peersFor(container) {
    try { return JSON.parse(container.dataset.peers || '[]'); }
    catch { return []; }
  }

  async function loadMessages(container, force = false) {
    if (!client || !container || pendingLoads.has(container)) return;
    if (container.closest('details') && !container.closest('details').open) return;
    const lastLoad = loadedAt.get(container) || 0;
    if (!force && Date.now() - lastLoad < 1800) return;
    pendingLoads.add(container);
    const status = container.querySelector('[data-chat-status]');
    try {
      const { data, error } = await client.from('simulation_messages')
        .select('id, order_id, sender_id, recipient_id, body, created_at')
        .eq('order_id', container.dataset.orderId)
        .order('created_at', { ascending: true })
        .limit(100);
      if (error) throw error;

      const messages = data || [];
      const peers = peersFor(container);
      const names = new Map(peers.map(peer => [peer.owner_id, peer.name]));
      if (role === 'admin') {
        const senderIds = [...new Set(messages.map(message => message.sender_id).filter(Boolean))];
        if (senderIds.length) {
          const result = await client.from('profiles').select('id, display_name').in('id', senderIds);
          if (!result.error) (result.data || []).forEach(profile => {
            if (!names.has(profile.id)) names.set(profile.id, profile.display_name);
          });
        }
      }

      const list = container.querySelector('[data-chat-messages]');
      list.innerHTML = messages.map(message => {
        const isMine = message.sender_id === userId;
        const sender = isMine ? displayName : (names.get(message.sender_id) || 'Counterparty');
        const timestamp = new Date(message.created_at).toLocaleString();
        return `<div class="max-w-[90%] rounded-lg px-3 py-2 ${isMine ? 'ml-auto bg-emerald-500/10 border border-emerald-500/20' : 'bg-slate-900 border border-slate-800'}">
          <div class="flex items-center justify-between gap-4 text-[9px] text-slate-500"><span>${escapeHtml(sender)}</span><time>${escapeHtml(timestamp)}</time></div>
          <p class="mt-1 whitespace-pre-wrap break-words text-[11px] text-slate-200">${escapeHtml(message.body)}</p>
        </div>`;
      }).join('') || '<div class="py-3 text-center text-[10px] text-slate-500">No messages yet.</div>';
      loadedAt.set(container, Date.now());
      if (status) status.textContent = '';
    } catch (error) {
      if (status) status.textContent = /simulation_messages|schema cache/i.test(error.message || '')
        ? 'Chat setup required: run supabase-chat-migration.sql.'
        : 'Could not load messages. Check chat access and Supabase connectivity.';
    } finally {
      pendingLoads.delete(container);
    }
  }

  function refreshVisible() {
    document.querySelectorAll('[data-trade-chat]').forEach(container => loadMessages(container));
  }

  async function sendMessage(form) {
    if (!client || !userId) return;
    const container = form.closest('[data-trade-chat]');
    const input = form.querySelector('[data-chat-input]');
    const recipient = form.querySelector('[data-chat-recipient]')?.value;
    const body = String(input?.value || '').trim();
    if (!recipient || !body) return;
    const button = form.querySelector('button[type="submit"]');
    if (button) button.disabled = true;
    const status = container.querySelector('[data-chat-status]');
    try {
      const { error } = await client.from('simulation_messages').insert({
        order_id: container.dataset.orderId,
        sender_id: userId,
        recipient_id: recipient,
        body
      });
      if (error) throw error;
      input.value = '';
      await loadMessages(container, true);
    } catch (error) {
      if (status) status.textContent = /simulation_messages|schema cache/i.test(error.message || '')
        ? 'Chat setup required: run supabase-chat-migration.sql.'
        : 'Message could not be sent. Check that this trade is matched.';
    } finally {
      if (button) button.disabled = false;
    }
  }

  function handleSubmit(event) {
    const form = event.target.closest('[data-trade-chat-form]');
    if (!form) return;
    event.preventDefault();
    sendMessage(form);
  }

  function start(detail) {
    client = detail.client;
    userId = detail.session.user.id;
    role = String(document.documentElement.dataset.authRole || '').toLowerCase();
    displayName = detail.profile?.display_name || 'You';
    if (refreshTimer) clearInterval(refreshTimer);
    refreshTimer = setInterval(refreshVisible, 2500);
    refreshVisible();
  }

  document.addEventListener('submit', handleSubmit);
  document.addEventListener('toggle', event => {
    if (event.target.matches('details[data-chat-details]') && event.target.open) refreshVisible();
  }, true);
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) refreshVisible();
  });
  window.addEventListener('matrix:authenticated', event => start(event.detail));
  window.addEventListener('matrix:signed-out', () => {
    if (refreshTimer) clearInterval(refreshTimer);
    refreshTimer = null;
    client = null;
    userId = null;
  });
})();