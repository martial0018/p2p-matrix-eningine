(() => {
  const url = window.MATRIX_SUPABASE_URL;
  const anonKey = window.MATRIX_SUPABASE_ANON_KEY;
  const configured = url && anonKey && !url.includes('YOUR_PROJECT') && !anonKey.includes('YOUR_SUPABASE');
  const supabase = configured && window.supabase ? window.supabase.createClient(url, anonKey) : null;
  window.MATRIX_SUPABASE_CLIENT = supabase;
  const roleButtons = { buyer: 'BUYER', seller: 'SELLER', arbiter: 'ARBITER', moderator: 'MODERATOR', admin: 'ADMIN' };
  const domainRoles = window.MATRIX_ROLE_DOMAINS || {};
  const regularRoles = ['buyer', 'seller'];
  const adminOnlyTabs = ['agents', 'stress', 'monte', 'rules', 'logs'];

  function roleForHostname() {
    const hostname = window.location.hostname.toLowerCase();
    return Object.entries(domainRoles).find(([, domain]) => String(domain).toLowerCase() === hostname)?.[0] || null;
  }

  function domainAllowsRole(domainRole, profileRole) {
    return !domainRole || domainRole === profileRole || (domainRole === 'regular' && regularRoles.includes(profileRole));
  }

  const style = document.createElement('style');
  style.textContent = `.auth-screen{position:fixed;inset:0;z-index:100;display:grid;place-items:center;background:radial-gradient(circle at 70% 0%,#17383b 0,transparent 32%),#071012;color:#e7f0ec;font-family:DM Sans,sans-serif}.auth-card{width:min(420px,calc(100% - 32px));padding:28px;background:#0d191b;border:1px solid #31504c;border-radius:14px;box-shadow:0 24px 90px #000b}.auth-card h2{margin:0 0 7px;font-size:24px}.auth-card p{color:#849995;font-size:12px;line-height:1.5;margin:0 0 20px}.auth-field{width:100%;box-sizing:border-box;background:#081213;border:1px solid #203234;border-radius:7px;color:#e7f0ec;padding:11px;margin:5px 0 10px}.auth-submit{width:100%;border:0;border-radius:7px;background:#9de8b9;color:#062016;padding:11px;font-weight:700;margin-top:7px;cursor:pointer}.auth-toggle{border:0;background:transparent;color:#92c8ff;cursor:pointer;font-size:11px;margin-top:14px}.auth-error{color:#ff8e86;font-size:11px;min-height:17px;margin-top:10px}.auth-config{color:#f3c66c;font-size:11px;background:#2b2112;border:1px solid #6a5123;padding:10px;border-radius:7px}.session-bar{position:fixed;top:68px;right:18px;z-index:60;display:flex;align-items:center;gap:9px;background:#102022;border:1px solid #31504c;border-radius:7px;padding:7px 10px;color:#b8c8c3;font:10px 'Space Mono',monospace}.session-bar button{border:1px solid #63363a;background:#3b1d22;color:#ff8e86;border-radius:5px;padding:4px 7px;font-size:10px;cursor:pointer}`;
  document.head.appendChild(style);

  function authCard() {
    const screen = document.createElement('div');
    screen.className = 'auth-screen';
    screen.innerHTML = `<form class="auth-card"><h2>Enter Matrix Engine</h2><p>Sign in to access your role-specific settlement workspace. Payments remain simulated in this version.</p><label>Email<input class="auth-field" type="email" name="email" required autocomplete="email"></label><label>Password<input class="auth-field" type="password" name="password" required minlength="6" autocomplete="current-password"></label><label class="display-field" hidden>Full name<input class="auth-field" type="text" name="display_name" maxlength="80" autocomplete="name"></label><label class="phone-field" hidden>Phone number (optional)<input class="auth-field" type="tel" name="phone" maxlength="24" autocomplete="tel"></label><button class="auth-submit" type="submit">Sign in</button><button class="auth-toggle" type="button">Create an account</button><div class="auth-error"></div></form>`;
    document.body.appendChild(screen);
    return screen;
  }

  function setupAuthForm(screen) {
    const form = screen.querySelector('form');
    const toggle = screen.querySelector('.auth-toggle');
    const display = screen.querySelector('.display-field');
    const phone = screen.querySelector('.phone-field');
    let signUp = false;
    toggle.onclick = () => { signUp = !signUp; display.hidden = !signUp; phone.hidden = !signUp; form.querySelector('.auth-submit').textContent = signUp ? 'Create account' : 'Sign in'; toggle.textContent = signUp ? 'Use existing account' : 'Create an account'; };
    form.onsubmit = async (event) => {
      event.preventDefault();
      const submit = form.querySelector('.auth-submit');
      if (submit.disabled) return;
      submit.disabled = true;
      submit.textContent = signUp ? 'Creating account...' : 'Signing in...';
      const data = new FormData(form); const email = data.get('email'); const password = data.get('password');
      try {
        const result = signUp ? await supabase.auth.signUp({ email, password, options: { data: { display_name: data.get('display_name') || 'New user', phone: data.get('phone') || '' } } }) : await supabase.auth.signInWithPassword({ email, password });
        if (result.error) throw result.error;
        if (signUp && !result.data.session) {
          screen.querySelector('.auth-error').textContent = 'Account created. Check your email to confirm it, then sign in.';
          submit.disabled = false;
          submit.textContent = 'Sign in';
          return;
        }
        await startSession(screen, result.data.session);
      } catch (error) {
        const message = String(error?.message || error);
        screen.querySelector('.auth-error').textContent = /rate limit|email rate/i.test(message)
          ? 'Supabase email limit reached. Wait a while, or configure custom SMTP in Supabase Auth settings.'
          : message;
        submit.disabled = false;
        submit.textContent = signUp ? 'Create account' : 'Sign in';
      }
    };
  }

  function showConfigMessage() {
    const screen = document.createElement('div'); screen.className = 'auth-screen';
    screen.innerHTML = `<div class="auth-card"><h2>Connect Supabase</h2><p>Authentication is ready, but this deployment still needs your Supabase project settings.</p><div class="auth-config">Set MATRIX_SUPABASE_URL and MATRIX_SUPABASE_ANON_KEY in supabase-config.js, then deploy again.</div></div>`;
    document.body.appendChild(screen);
  }

  function applyRole(role) {
    const normalized = String(role || 'buyer').toLowerCase();
    const domainRole = roleForHostname();
    if (!domainAllowsRole(domainRole, normalized)) return false;
    document.documentElement.dataset.authRole = normalized;
    const canManageAllRoles = normalized === 'admin';
    adminOnlyTabs.forEach((tab) => {
      const button = document.getElementById(`nav-${tab}`);
      if (button) {
        button.hidden = !canManageAllRoles;
        if (canManageAllRoles) button.style.removeProperty('display');
        else button.style.setProperty('display', 'none', 'important');
      }
    });
    Object.entries(roleButtons).forEach(([name, value]) => {
      const button = document.getElementById(`role-${name}`);
      if (button) button.hidden = !canManageAllRoles && normalized !== name;
    });
    if (typeof window.setRole === 'function') window.setRole(canManageAllRoles ? 'ADMIN' : roleButtons[normalized]);
    return true;
  }

  function populateProfile(profile, session) {
    const name = profile.display_name || session.user.user_metadata?.display_name || '';
    const phone = Object.prototype.hasOwnProperty.call(profile, 'phone')
      ? profile.phone || ''
      : session.user.user_metadata?.phone || '';
    document.getElementById('profile-display-name').value = name;
    document.getElementById('profile-email').value = session.user.email || '';
    document.getElementById('profile-phone').value = phone;
    window.MATRIX_PROFILE_DISPLAY_NAME = name;
    window.MATRIX_PROFILE_PHONE = phone;
    window.MATRIX_AUTH_EMAIL = session.user.email || '';
  }

  async function saveProfile(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const button = document.getElementById('profile-save');
    const status = document.getElementById('profile-status');
    const displayName = form.elements.display_name.value.trim();
    const phone = form.elements.phone.value.trim();
    if (!supabase || !window.MATRIX_AUTH_USER_ID) {
      status.textContent = 'Sign in to update your profile.';
      status.className = 'text-[10px] text-rose-300';
      return;
    }
    if (!displayName || displayName.length > 80) {
      status.textContent = 'Enter a name between 1 and 80 characters.';
      status.className = 'text-[10px] text-rose-300';
      return;
    }
    button.disabled = true;
    status.textContent = 'Saving...';
    status.className = 'text-[10px] text-slate-400';
    try {
      const { data, error } = await supabase.rpc('update_my_profile', {
        p_display_name: displayName,
        p_phone: phone || null
      });
      if (error) throw error;
      const updated = {
        display_name: data?.display_name || displayName,
        phone: data?.phone || ''
      };
      populateProfile(updated, { user: { email: window.MATRIX_AUTH_EMAIL, user_metadata: updated } });
      const sessionName = document.querySelector('.session-bar span');
      if (sessionName) sessionName.textContent = `${updated.display_name} · ${document.documentElement.dataset.authRole}`;
      window.dispatchEvent(new CustomEvent('matrix:profile-updated', { detail: updated }));
      status.textContent = 'Profile saved.';
      status.className = 'text-[10px] text-emerald-300';
    } catch (error) {
      status.textContent = error?.message || 'Could not save your profile.';
      status.className = 'text-[10px] text-rose-300';
    } finally {
      button.disabled = false;
    }
  }

  async function boot() {
    if (!supabase) return showConfigMessage();
    adminOnlyTabs.forEach((tab) => {
      const button = document.getElementById(`nav-${tab}`);
      if (button) {
        button.hidden = true;
        button.style.setProperty('display', 'none', 'important');
      }
    });
    const screen = authCard();
    setupAuthForm(screen);
    const { data } = await supabase.auth.getSession();
    if (data.session) await startSession(screen, data.session);
    supabase.auth.onAuthStateChange((event, session) => {
      if (event === 'SIGNED_OUT' && !session) {
        window.dispatchEvent(new Event('matrix:signed-out'));
        document.querySelector('.session-bar')?.remove();
        if (!document.querySelector('.auth-screen')) setupAuthForm(authCard());
      }
    });
  }

  async function startSession(screen, session) {
    window.MATRIX_AUTH_USER_ID = session.user.id;
    let result = await Promise.race([
      supabase.from('profiles').select('display_name, role').eq('id', session.user.id).maybeSingle(),
      new Promise((resolve) => setTimeout(() => resolve({ data: null, error: { message: 'Profile lookup timed out.' } }), 6000))
    ]);
    const profile = result.data || { display_name: session.user.user_metadata?.display_name || session.user.email, role: 'buyer' };
    let contactError = null;
    const contactResult = await Promise.race([
      supabase.from('profile_contacts').select('phone').eq('user_id', session.user.id).maybeSingle(),
      new Promise((resolve) => setTimeout(() => resolve({ data: null, error: { message: 'Profile contact lookup timed out.' } }), 6000))
    ]);
    const profilePhoneMigrationMissing = Boolean(contactResult.error &&
      /profile_contacts|schema cache|timed out/i.test(contactResult.error.message || ''));
    if (contactResult.error && !profilePhoneMigrationMissing) {
      contactError = contactResult.error.message;
    }
    profile.phone = contactResult.data?.phone ||
      (profilePhoneMigrationMissing ? session.user.user_metadata?.phone || '' : '');
    populateProfile(profile, session);
    const profileForm = document.getElementById('profile-form');
    if (profileForm && !profileForm.dataset.bound) {
      profileForm.addEventListener('submit', saveProfile);
      profileForm.dataset.bound = 'true';
    }
    if (profilePhoneMigrationMissing || contactError) {
      document.getElementById('profile-save').disabled = true;
      document.getElementById('profile-status').textContent = profilePhoneMigrationMissing
        ? 'Run the latest supabase-chat-migration.sql to enable profile updates.'
        : `Could not load your phone number: ${contactError}`;
      document.getElementById('profile-status').className = profilePhoneMigrationMissing
        ? 'text-[10px] text-amber-300'
        : 'text-[10px] text-rose-300';
    }
    const profileMissing = result.error && /profiles|schema cache|timed out/i.test(result.error.message || '');
    if (result.error && !profileMissing) return screen.querySelector('.auth-error').textContent = result.error.message;
    const domainRole = roleForHostname();
    if (!domainAllowsRole(domainRole, String(profile.role).toLowerCase())) {
      screen.querySelector('.auth-error').textContent = `This account has ${profile.role} access. Use the correct role domain.`;
      await supabase.auth.signOut();
      return;
    }
    applyRole(profile.role);
    screen.remove();
    setTimeout(() => {
      window.dispatchEvent(new CustomEvent('matrix:authenticated', { detail: { client: supabase, session, profile } }));
    }, 0);
    document.querySelector('.session-bar')?.remove();
    const bar = document.createElement('div');
    bar.className = 'session-bar';
    bar.innerHTML = '<span></span><button type="button">Sign out</button>';
    bar.querySelector('span').textContent = `${profile.display_name} · ${profile.role}${profileMissing ? ' · setup needed' : ''}`;
    document.body.appendChild(bar);
    if (profileMissing && typeof toast === 'function') toast('Database setup needed', 'Run supabase-schema.sql to enable roles and persistence.', 'err');
    bar.querySelector('button').onclick = () => supabase.auth.signOut();
  }

  window.addEventListener('matrix:profile-updated', (event) => {
    const updated = event.detail || {};
    window.MATRIX_PROFILE_DISPLAY_NAME = updated.display_name || window.MATRIX_PROFILE_DISPLAY_NAME;
    window.MATRIX_PROFILE_PHONE = updated.phone || '';
  });

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();
