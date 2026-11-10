#!/usr/bin/env bash
# Testa supabase/schema.sql num Postgres local (16+), com imitações mínimas
# de auth, realtime e dos privilégios padrão do Supabase.
#   PGPORT=5433 ./supabase/test/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
export PGOPTIONS="-c client_min_messages=warning" PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-5433}"
DB=senhas_test

dropdb --if-exists "$DB"
createdb "$DB"
P() { psql -X -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }

P -f supabase/test/stubs.sql
# aplica o schema até o marcador do pg_cron (indisponível localmente)
sed '/^-- @cron/,$d' supabase/schema.sql | P
# duas vezes: precisa ser idempotente
sed '/^-- @cron/,$d' supabase/schema.sql | P
P -o /dev/null -f supabase/test/tests.sql
echo "OK: todos os testes passaram"
dropdb "$DB"
