(() => {
  let activeUserId = null;
  let client = null;
  let refreshTimer = null;

  const byId = id => document.getElementById(id);

  function setStatus(message, isError = false) {
    const status = byId('ref-status');
    if (!status) return;
    status.textContent = message;
    status.className = `mt-2 min-h-3 text-[9px] ${isError ? 'text-rose-300' : 'text-slate-500'}`;
  }

  function clearReferralData() {
    activeUserId = null;
    client = null;
    window.MATRIX_REFERRALS = [];
    const link = byId('ref-link');
    const copy = byId('ref-copy');
    if (link) link.value = '';
    if (copy) copy.disabled = true;
    setStatus('Sign in to load your referral link.');
    if (typeof window.renderTree === 'function') window.renderTree();
  }

  function activate(clientInstance, userId) {
    client = clientInstance;
    activeUserId = userId;
    loadReferralData().catch(error => {
      console.error('Could not load referral data:', error);
      const message = /referral_code|get_my_referrals|schema cache|does not exist/i.test(error.message || '')
        ? 'Referral database setup needed. Run supabase-referrals-migration.sql.'
        : error.message || 'Could not load referral data. Check your connection and database setup.';
      setStatus(message, true);
    });
    if (refreshTimer) clearInterval(refreshTimer);
    refreshTimer = setInterval(() => {
      if (!document.hidden) {
        loadReferralData().catch(error => {
          console.error('Could not refresh referral data:', error);
          const message = /referral_code|get_my_referrals|schema cache|does not exist/i.test(error.message || '')
            ? 'Referral database setup needed. Run supabase-referrals-migration.sql.'
            : error.message || 'Could not refresh referral data.';
          setStatus(message, true);
        });
      }
    }, 30000);
  }

  async function loadReferralData() {
    if (!client || !activeUserId) return;
    setStatus('Loading your referral information...');
    const profileResult = await client.from('profiles')
      .select('referral_code')
      .eq('id', activeUserId)
      .maybeSingle();
    if (profileResult.error) throw profileResult.error;
    const referralCode = profileResult.data?.referral_code;
    if (!referralCode) {
      throw new Error('Referral setup is incomplete. Run supabase-referrals-migration.sql.');
    }

    const pageUrl = new URL(window.location.href);
    if (!['http:', 'https:'].includes(pageUrl.protocol)) {
      throw new Error('Referral links are available after the site is deployed to an HTTP or HTTPS address.');
    }
    const signupPath = document.documentElement.dataset.referralSignupPath;
    if (signupPath) pageUrl.pathname = signupPath;
    pageUrl.searchParams.set('ref', referralCode);
    const link = byId('ref-link');
    const copy = byId('ref-copy');
    if (link) link.value = pageUrl.toString();
    if (copy) copy.disabled = false;

    const result = await client.rpc('get_my_referrals');
    if (result.error) throw result.error;
    window.MATRIX_REFERRALS = result.data || [];
    if (typeof window.renderTree === 'function') window.renderTree();
    setStatus('Link ready. Only new accounts created through it are attributed.');
  }

  window.copyLink = async function copyLink() {
    const input = byId('ref-link');
    if (!input?.value) {
      setStatus('Your invite link is not available yet.', true);
      return;
    }
    try {
      await navigator.clipboard.writeText(input.value);
    } catch (error) {
      input.focus();
      input.select();
      const copied = document.execCommand('copy');
      input.setSelectionRange(0, 0);
      if (!copied) {
        setStatus('Could not copy the link. Select it and copy manually.', true);
        return;
      }
    }
    setStatus('Invite link copied.');
    if (typeof window.toast === 'function') window.toast('Copied', 'Personal invite link copied.', 'info');
  };

  window.addEventListener('matrix:authenticated', event => {
    activate(event.detail.client, event.detail.session.user.id);
  });

  window.addEventListener('matrix:signed-out', () => {
    if (refreshTimer) clearInterval(refreshTimer);
    refreshTimer = null;
    clearReferralData();
  });

  if (document.documentElement.dataset.referralStandalone === 'true') {
    const supabaseUrl = window.MATRIX_SUPABASE_URL;
    const anonKey = window.MATRIX_SUPABASE_ANON_KEY;
    if (window.supabase && supabaseUrl && anonKey) {
      const standaloneClient = window.supabase.createClient(supabaseUrl, anonKey);
      standaloneClient.auth.getSession().then(({ data, error }) => {
        if (error) throw error;
        if (data.session) activate(standaloneClient, data.session.user.id);
        else setStatus('Sign in through the main app to load referral information.');
      }).catch(error => {
        console.error('Could not connect to referral account:', error);
        setStatus('Could not connect to the account. Sign in through the main app and try again.', true);
      });
    }
  }
})();
