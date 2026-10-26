-- Gesta 3.1 · amici veri
-- Da incollare una volta nell'SQL Editor di Supabase (New query → snippet) e premere Run.
-- Si può rilanciare senza problemi: crea solo ciò che manca e aggiorna le funzioni.

-- link d'invito personale (segreto, diverso dal codice amico)
alter table public.profiles add column if not exists invite_token uuid not null default gen_random_uuid();
create unique index if not exists profiles_invite_token on public.profiles (invite_token);

-- mandare una richiesta con il codice amico.
-- Se l'altro ti aveva già chiesto l'amicizia, diventate amici subito.
create or replace function public.send_friend_request(code text)
returns table (status text, name text)
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); t uuid; tn text; r friend_requests;
begin
  if me is null then raise exception 'non autenticato'; end if;
  select p.id, p.name into t, tn from profiles p where p.friend_code = upper(trim(code));
  if t is null then return query select 'nessuno'::text, null::text; return; end if;
  if t = me then return query select 'tu'::text, tn; return; end if;
  if is_friend(me, t) then return query select 'amici'::text, tn; return; end if;
  select * into r from friend_requests where from_id = t and to_id = me and friend_requests.status = 'pending';
  if found then
    update friend_requests set status = 'accepted' where id = r.id;
    insert into friendships (user_a, user_b) values (least(me, t), greatest(me, t)) on conflict do nothing;
    return query select 'accettata'::text, tn; return;
  end if;
  insert into friend_requests (from_id, to_id, status) values (me, t, 'pending')
    on conflict (from_id, to_id) do update set status = 'pending', created_at = now();
  return query select 'inviata'::text, tn;
end; $$;

-- le richieste che ho ricevuto (con il nome di chi me le manda)
create or replace function public.friend_inbox()
returns table (id uuid, from_id uuid, name text, gender text, summary jsonb, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select r.id, r.from_id, p.name, p.gender, p.summary, r.created_at
  from friend_requests r join profiles p on p.id = r.from_id
  where r.to_id = auth.uid() and r.status = 'pending'
  order by r.created_at desc;
$$;

-- le richieste che ho mandato e aspettano risposta
create or replace function public.friend_outbox()
returns table (id uuid, to_id uuid, name text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select r.id, r.to_id, p.name, r.created_at
  from friend_requests r join profiles p on p.id = r.to_id
  where r.from_id = auth.uid() and r.status = 'pending'
  order by r.created_at desc;
$$;

-- rifiutare una richiesta
create or replace function public.decline_friend(req uuid) returns void
language sql security definer set search_path = public as $$
  update friend_requests set status = 'declined' where id = req and to_id = auth.uid();
$$;

-- il nome di chi ti invita, per mostrarlo prima ancora di entrare
create or replace function public.invite_name(tok uuid) returns text
language sql stable security definer set search_path = public as $$
  select name from profiles where invite_token = tok;
$$;

-- accettare un invito arrivato col link: si diventa amici subito
create or replace function public.accept_invite(tok uuid)
returns table (status text, name text)
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); t uuid; tn text;
begin
  if me is null then raise exception 'non autenticato'; end if;
  select p.id, p.name into t, tn from profiles p where p.invite_token = tok;
  if t is null then return query select 'nessuno'::text, null::text; return; end if;
  if t = me then return query select 'tu'::text, tn; return; end if;
  insert into friendships (user_a, user_b) values (least(me, t), greatest(me, t)) on conflict do nothing;
  update friend_requests set status = 'accepted'
    where friend_requests.status = 'pending' and ((from_id = me and to_id = t) or (from_id = t and to_id = me));
  return query select 'amici'::text, tn;
end; $$;
