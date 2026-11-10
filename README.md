# Senhas de Atendimento

Sistema de senhas para filas de atendimento: totem, guichê, painel com voz,
acompanhamento pelo celular (QR code) e relatórios. Projeto de vitrine em
https://senhas.wllynilson.com.br.

- **Front-end:** HTML, CSS e JavaScript puro (ES modules), sem build, no GitHub Pages
- **Back-end:** Supabase (Postgres, Auth anônimo, Realtime)

## Funcionalidades

| Tela | Rota | Quem usa |
|---|---|---|
| Início | `#/` | Visitante cria a própria unidade de demonstração (login anônimo) |
| Totem | `#/totem/<token>` | Público: escolhe serviço, normal ou preferencial; imprime cupom 80 mm e mostra QR |
| Painel | `#/painel/<token>` | TV: senha atual, últimas chamadas, som e voz (pt-BR) |
| Acompanhamento | `#/senha/<código>` | Celular: posição na fila e alerta (vibração/som) ao ser chamado |
| Guichê | `#/guiche` | Atendente: chamar próxima, rechamar, finalizar, ausente (atalhos N, R, F) |
| Relatórios | `#/relatorios` | Indicadores, senhas por dia e por hora, tabela por serviço |
| Configurar | `#/config` | Nome da unidade, serviços (letra), histórico de exemplo, zerar o dia |

Regras da fila:
- Numeração por serviço e por dia: `A001`; preferencial com numeração própria: `AP001`.
- Preferenciais são chamadas primeiro (Lei 10.048/2000), depois a ordem de chegada.
- `call_next` usa `for update skip locked`: dois guichês nunca pegam a mesma senha.
- Chamar a próxima finaliza automaticamente a senha que estava no guichê.

## Segurança

- Cada visitante entra com **login anônimo** e só enxerga a própria unidade (RLS).
- Totem, painel e acompanhamento funcionam **sem login**, por funções `security definer`
  que recebem um token aleatório (`kiosk_token` da unidade ou `public_code` da senha).
  A senha (QR) só dá acesso ao andamento dela mesma.
- Usuários não alteram senhas diretamente: todas as mudanças passam por funções que
  validam o estado (`call_next`, `recall_ticket`, `finish_ticket`).
- Limite de 30 senhas por minuto por unidade e 999 por serviço/dia.
- Tempo real: o banco envia só um aviso "mudou" no canal `unit:<token>`; as telas buscam
  os dados pelas funções. Há consulta periódica caso o tempo real caia.
- Unidades sem uso por 30 dias são apagadas (`pg_cron`).

## Configuração do Supabase (uma vez)

1. Crie um projeto em https://supabase.com (região **South America (São Paulo)**).
2. **Authentication → Sign In / Providers**: ative **Allow anonymous sign-ins**.
3. **SQL Editor → New query**: cole `supabase/schema.sql` e clique em **Run**.
4. Copie a URL do projeto e a *Publishable key* (**Project Settings → API Keys**) para `js/config.js`.
   Nunca use a *Secret key* nem a `service_role`.

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
