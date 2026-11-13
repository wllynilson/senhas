# Senhas de Atendimento

Sistema de senhas para filas de atendimento: totem, guichê, painel com voz,
acompanhamento pelo celular (QR code e Web Push), transferência entre serviços
e relatórios. Projeto de vitrine em https://senhas.wllynilson.com.br.

- **Front-end:** HTML, CSS e JavaScript puro (ES modules), sem build, no GitHub Pages
- **Back-end:** Supabase (Postgres, Auth anônimo, Realtime, Edge Functions)

## Funcionalidades

| Tela | Rota | Quem usa |
|---|---|---|
| Início | `#/` | Visitante cria a própria unidade de demonstração (login anônimo) |
| Totem | `#/totem/<token>` | Público: escolhe serviço e tipo de atendimento; imprime cupom 80 mm e mostra QR |
| Painel | `#/painel/<token>` | TV: senha atual, últimas chamadas, som e voz (pt-BR). Token só de leitura |
| Acompanhamento | `#/senha/<código>` | Celular: posição, espera estimada e alerta (vibração/som/Web Push) |
| Guichê | `#/guiche` | Atendente: chamar, rechamar, finalizar, ausente, transferir e emitir no balcão |
| Relatórios | `#/relatorios` | Indicadores (média, p50, p90, meta), por dia/hora/serviço/guichê e CSV |
| Configurar | `#/config` | Unidade, serviços, guichês, meta de espera, trocar links e zerar o dia |

Regras da fila:
- Numeração por serviço, prioridade e dia: `A001`; prioritária `AP001`; 80+ `AE001`; doador `AD001`.
- Quatro níveis de prioridade (Lei 10.048/2000 na redação da Lei 14.626/2023 e
  Estatuto da Pessoa Idosa, art. 3º, §2º): 80+ → prioritário → doador de sangue → normal.
- Guichê pode ser exclusivo de prioritárias (Lei 14.626, art. 1º, §3º).
- `call_next` usa `for update skip locked`: dois guichês nunca pegam a mesma senha.
- Chamar a próxima finaliza automaticamente a senha que estava no guichê.
- Passado o limite de rechamadas (padrão 3), a senha vira ausente sozinha.
- Senhas esquecidas de dias anteriores viram `expired` (cron de hora em hora).

## Segurança

- Cada visitante entra com **login anônimo** e só enxerga a própria unidade (RLS).
- Totem e painel usam **tokens diferentes**. O do painel só lê; o do totem emite
  senhas. Dá para trocá-los em Configurar (`rotate_tokens`).
- Acompanhamento por QR e inscrição de Web Push funcionam **sem login**, por
  funções `security definer` que recebem o `public_code` da senha.
- Usuários não alteram senhas diretamente: todas as mudanças passam por funções
  (`call_next`, `recall_ticket`, `finish_ticket`, `transfer_ticket`).
- Limite de 30 senhas por minuto por unidade e 999 por serviço/prioridade/dia.
- Tempo real: o banco avisa nos canais `unit:<token>` e `ticket:<código>`; as
  telas buscam os dados pelas funções. Há consulta periódica caso o tempo real caia.
- As bibliotecas (`supabase-js`, `qrcode-generator`) ficam em `js/vendor/`; a
  Content-Security-Policy em `index.html` não libera código de CDN.
- Unidades sem uso por 30 dias são apagadas (`pg_cron`).

## Configuração do Supabase (uma vez)

1. Crie um projeto em https://supabase.com (região **South America (São Paulo)**).
2. **Authentication → Sign In / Providers**: ative **Allow anonymous sign-ins**.
3. **SQL Editor → New query**: cole `supabase/schema.sql` e clique em **Run**.
4. Copie a URL do projeto e a *Publishable key* (**Project Settings → API Keys**)
   para `js/config.js`. Ajuste também o `connect-src` da CSP em `index.html`.
   Nunca use a *Secret key* nem a `service_role`.

### Web Push (opcional)

Sem as chaves VAPID o acompanhamento no celular continua funcionando; só some o
botão "Avisar quando chegar minha vez".

```bash
npx web-push generate-vapid-keys
# publique a chave pública em js/config.js (VAPID_PUBLIC_KEY)
supabase secrets set VAPID_PUBLIC_KEY=… VAPID_PRIVATE_KEY=… \
  VAPID_SUBJECT=mailto:voce@exemplo.com NOTIFY_SECRET=<segredo> \
  APP_URL=https://senhas.wllynilson.com.br
supabase functions deploy notify --no-verify-jwt
```

No SQL Editor:

```sql
insert into public.app_config (notify_url, notify_secret)
values ('https://<ref>.supabase.co/functions/v1/notify', '<segredo>')
on conflict (id) do update
  set notify_url = excluded.notify_url, notify_secret = excluded.notify_secret;
```

## Testes do banco

Num Postgres 16 local (com imitações de `auth` e `realtime`):

```bash
PGPORT=5433 ./supabase/test/run.sh
```

## Rodar localmente

```bash
python3 -m http.server 8080
```

Abra http://localhost:8080.
