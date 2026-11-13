// Edge Function "notify": envia o Web Push de "é a sua vez" para quem leu o
// QR code e pediu o aviso. Chamada pelo gatilho do banco (public.app_config).
//
// Como publicar (uma vez, com a CLI do Supabase):
//   npx web-push generate-vapid-keys
//   supabase secrets set VAPID_PUBLIC_KEY=... VAPID_PRIVATE_KEY=... \
//       VAPID_SUBJECT=mailto:voce@exemplo.com NOTIFY_SECRET=<segredo>
//   supabase functions deploy notify --no-verify-jwt
//
// Depois, no SQL Editor:
//   insert into public.app_config (notify_url, notify_secret)
//   values ('https://<ref>.supabase.co/functions/v1/notify', '<segredo>')
//   on conflict (id) do update set notify_url = excluded.notify_url,
//                                  notify_secret = excluded.notify_secret;
import { createClient } from 'jsr:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

const SECRET = Deno.env.get('NOTIFY_SECRET') ?? '';
const APP_URL = Deno.env.get('APP_URL') ?? 'https://senhas.wllynilson.com.br';

webpush.setVapidDetails(
    Deno.env.get('VAPID_SUBJECT') ?? 'mailto:contato@exemplo.com',
    Deno.env.get('VAPID_PUBLIC_KEY') ?? '',
    Deno.env.get('VAPID_PRIVATE_KEY') ?? '',
);

const db = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
);

Deno.serve(async (req) => {
    if (req.headers.get('Authorization') !== `Bearer ${SECRET}` || !SECRET) {
        return new Response('não autorizado', { status: 401 });
    }
    const { tickets } = await req.json().catch(() => ({ tickets: [] }));
    if (!Array.isArray(tickets) || tickets.length === 0) {
        return new Response('nada a enviar', { status: 200 });
    }

    const { data, error } = await db
        .from('tickets')
        .select('id, code, counter_name, public_code, push_subscriptions(endpoint, p256dh, auth)')
        .in('id', tickets.slice(0, 100))
        .eq('status', 'called');
    if (error) return new Response(error.message, { status: 500 });

    const expired: string[] = [];
    await Promise.all((data ?? []).flatMap((t) =>
        (t.push_subscriptions ?? []).map(async (s: { endpoint: string; p256dh: string; auth: string }) => {
            const payload = JSON.stringify({
                title: `Senha ${t.code}: é a sua vez`,
                body: t.counter_name ? `Dirija-se ao ${t.counter_name}.` : 'Dirija-se ao atendimento.',
                tag: `senha-${t.public_code}`,
                url: `${APP_URL}/#/senha/${t.public_code}`,
            });
            try {
                await webpush.sendNotification(
                    { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
                    payload,
                );
            } catch (e) {
                // 404/410: o navegador descartou a inscrição
                const code = (e as { statusCode?: number }).statusCode;
                if (code === 404 || code === 410) expired.push(s.endpoint);
                else console.error('push falhou', code, e);
            }
        })
    ));

    if (expired.length) await db.from('push_subscriptions').delete().in('endpoint', expired);
    return new Response('ok', { status: 200 });
});
