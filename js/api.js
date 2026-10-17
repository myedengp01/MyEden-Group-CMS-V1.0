// MyEden Group CMS V1.0 · connection to Supabase: sign-in and the cms_ database functions.
// The browser never reads or writes tables directly; every call goes through a checked function.
(function () {
  'use strict';
  const cfg = window.CMS_CONFIG;
  let client = null;

  function sb() {
    if (client) return client;
    if (!window.supabase || !window.supabase.createClient) {
      throw new Error('The sign-in library did not load. Check the internet connection and reload the page.');
    }
    client = window.supabase.createClient(cfg.url, cfg.key, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, storageKey: 'cms.auth' },
    });
    return client;
  }

  // Turn database and network errors into sentences people can act on.
  function friendly(err) {
    const m = String((err && (err.message || err.error_description || err.msg)) || err || 'Something went wrong');
    if (/Invalid login credentials/i.test(m)) return 'Email or password is not correct.';
    if (/Email not confirmed/i.test(m)) return 'This email has not been confirmed yet. Check your inbox for the confirmation link.';
    if (/Failed to fetch|NetworkError|Load failed/i.test(m)) return 'Cannot reach the CMS database. Check the internet connection and try again.';
    if (/JWT expired|invalid JWT/i.test(m)) return 'Your session has expired. Please sign in again.';
    if (/rate limit/i.test(m)) return 'Too many attempts. Please wait a minute and try again.';
    return m;
  }

  async function rpc(name, args) {
    const { data, error } = await sb().rpc(name, args || {});
    if (error) { const e = new Error(friendly(error)); e.code = error.code; throw e; }
    return data;
  }

  window.CMS_API = {
    sb,
    friendly,
    rpc,
    async session() { const { data } = await sb().auth.getSession(); return data.session || null; },
    async signIn(email, password) {
      const { data, error } = await sb().auth.signInWithPassword({ email, password });
      if (error) throw new Error(friendly(error));
      return data.session;
    },
    async signOut() { try { await sb().auth.signOut(); } catch (e) { /* already signed out */ } },
    async sendReset(email) {
      const redirectTo = location.href.split('#')[0];
      const { error } = await sb().auth.resetPasswordForEmail(email, { redirectTo });
      if (error) throw new Error(friendly(error));
    },
    async setPassword(password) {
      const { error } = await sb().auth.updateUser({ password });
      if (error) throw new Error(friendly(error));
    },
    onAuth(fn) { sb().auth.onAuthStateChange((event, session) => fn(event, session)); },
  };
})();
