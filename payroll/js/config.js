// MyPayroll pages inside the MyEden Group CMS: the connection comes from the CMS (same database, same sign-in).
const c = window.CMS_CONFIG || {};
export const MEGFORMS_URL = c.url;
export const MEGFORMS_ANON_KEY = c.key;
export const SUPABASE_URL = c.url;
export const SUPABASE_ANON_KEY = c.key;
