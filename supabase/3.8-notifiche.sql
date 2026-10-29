-- Gesta 3.8 · notifiche sul telefono
-- Da incollare una volta nell'SQL Editor di Supabase e premere Run. Si può rilanciare senza problemi.

-- la tabella c'era già dalla 3.1: aggiungo le preferenze (cosa vuoi ricevere) e la data dell'ultimo aggiornamento
alter table public.push_subscriptions add column if not exists prefs jsonb not null default '{}'::jsonb;
alter table public.push_subscriptions add column if not exists updated_at timestamptz not null default now();

-- ognuno vede e cambia solo i suoi telefoni (la regola c'era già, la riscrivo per sicurezza)
alter table public.push_subscriptions enable row level security;
drop policy if exists p_push_all on public.push_subscriptions;
create policy p_push_all on public.push_subscriptions for all using (user_id = auth.uid()) with check (user_id = auth.uid());
