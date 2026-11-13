// Dados públicos do projeto Supabase (Project Settings → API Keys).
// A chave publishable/anon é pública por design: o banco é protegido por RLS.
// Nunca coloque aqui a Secret key (sb_secret_…) nem a service_role.
// Ao trocar de projeto, ajuste também o connect-src da CSP em index.html.
export const SUPABASE_URL = 'https://znuwlbfmwocgmkxlrnto.supabase.co';
export const SUPABASE_ANON_KEY = 'sb_publishable_PhvL6CA1ML8rXIRL8qwK_A_tdsjW1qh';

// Chave pública VAPID do Web Push (opcional). Sem ela, o acompanhamento no
// celular continua funcionando, só não oferece o aviso em segundo plano.
export const VAPID_PUBLIC_KEY = '';
