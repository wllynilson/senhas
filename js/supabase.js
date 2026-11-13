// Cliente do Supabase. A biblioteca vem de js/vendor (carregada em index.html),
// e não de uma CDN: assim a Content-Security-Policy pode proibir código de fora.
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

const lib = window.supabase;
export const isConfigured = Boolean(SUPABASE_URL && SUPABASE_ANON_KEY && lib);

export const supabase = isConfigured
    ? lib.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: true, autoRefreshToken: true } })
    : null;
