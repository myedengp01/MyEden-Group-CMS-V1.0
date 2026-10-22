// MyPayroll pages inside the MyEden Group CMS: use the CMS's own Supabase client, so the CMS sign-in is used.
export const isConfigured = true;
const client = () => window.API.sb();
export const sb = new Proxy({}, { get: (_, k) => { const c = client(); const v = c[k]; return typeof v === 'function' ? v.bind(c) : v; } });
export const createClient = (...a) => window.supabase.createClient(...a);
