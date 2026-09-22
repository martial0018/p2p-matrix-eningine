(() => {
  const url = window.MATRIX_SUPABASE_URL;
  const anonKey = window.MATRIX_SUPABASE_ANON_KEY;
  const configured = url && anonKey && !url.includes('YOUR_PROJECT') && !anonKey.includes('YOUR_SUPABASE');
  const supabase = configured && window.supabase ? window.supabase.createClient(url, anonKey) : null;
  window.MATRIX_SUPABASE_CLIENT = supabase;
  const roleButtons = { buyer: 'BUYER', seller: 'SELLER', arbiter: 'ARBITER', moderator: 'MODERATOR', admin: 'ADMIN' };
  const domainRoles = window.MATRIX_ROLE_DOMAINS || {};
  const regularRoles = ['buyer', 'seller'];
  const adminOnlyTabs = ['agents', 'stress', 'monte', 'logs'];

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
    screen.innerHTML = `<form class="auth-card"><h2>Enter Matrix Engine</h2><p>Sign in to access your role-specific settlement workspace. Payments remain simulated in this version.</p><label>Email<input class="auth-field" type="email" name="email" required autocomplete="email"></label><label>Password<input class="auth-field" type="password" name="password" required minlength="6" autocomplete="current-password"></label><label class="display-field" hidden>Display name<input class="auth-field" type="text" name="display_name" autocomplete="name"></label><button class="auth-submit" type="submit">Sign in</button><button class="auth-toggle" type="button">Create an account</button><div class="auth-error"></div></form>`;
    document.body.appendChild(screen);
    return screen;
  }

  function setupAuthForm(screen) {
    const form = screen.querySelector('form');
    const toggle = screen.querySelector('.auth-toggle');
    const display = screen.querySelector('.display-field');
    let signUp = false;
    toggle.onclick = () => { signUp = !signUp; display.hidden = !signUp; form.querySelector('.auth-submit').textContent = signUp ? 'Create account' : 'Sign in'; toggle.textContent = signUp ? 'Use existing account' : 'Create an account'; };
    form.onsubmit = async (event) => {
      event.preventDefault();
      const submit = form.querySelector('.auth-submit');
      if (submit.disabled) return;
      submit.disabled = true;
      submit.textContent = signUp ? 'Creating account...' : 'Signing in...';
      const data = new FormData(form); const email = data.get('email'); const password = data.get('password');
      try {
        const result = signUp ? await supabase.auth.signUp({ email, password, options: { data: { display_name: data.get('display_name') || 'New user' } } }) : await supabase.auth.signInWithPassword({ email, password });
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
    const profileRequest = supabase.from('profiles').select('display_name, role').eq('id', session.user.id).maybeSingle();
    const result = await Promise.race([
      profileRequest,
      new Promise((resolve) => setTimeout(() => resolve({ data: null, error: { message: 'Profile lookup timed out.' } }), 6000))
    ]);
    const profile = result.data || { display_name: session.user.user_metadata?.display_name || session.user.email, role: 'buyer' };
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
    window.dispatchEvent(new CustomEvent('matrix:authenticated', { detail: { client: supabase, session, profile } }));
    document.querySelector('.session-bar')?.remove();
    const bar = document.createElement('div'); bar.className = 'session-bar'; bar.innerHTML = `<span>${profile.display_name} · ${profile.role}${profileMissing ? ' · setup needed' : ''}</span><button type="button">Sign out</button>`; document.body.appendChild(bar);
    if (profileMissing && typeof toast === 'function') toast('Database setup needed', 'Run supabase-schema.sql to enable roles and persistence.', 'err');
    bar.querySelector('button').onclick = () => supabase.auth.signOut();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();
