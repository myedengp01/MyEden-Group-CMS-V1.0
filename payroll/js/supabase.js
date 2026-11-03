// MyPayroll pages inside the MyEden Group CMS: use the CMS's own Supabase client, so the CMS sign-in is used.
export const isConfigured = true;
const client = () => (window.CMS_API || window.API).sb();  // the CMS client (window.CMS_API); the old name window.API never existed in the CMS
export const sb = new Proxy({}, { get: (_, k) => { const c = client(); const v = c[k]; return typeof v === 'function' ? v.bind(c) : v; } });
export const createClient = (...a) => window.supabase.createClient(...a);
