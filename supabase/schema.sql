-- Sistema · schema Supabase per la 3.0 (account e cloud) e la 3.1 (amici veri)
-- Da incollare una volta nell'SQL Editor di Supabase e premere Run.
-- Ogni tabella ha le regole di accesso (Row Level Security): ognuno legge e scrive solo il suo,
-- e degli amici vede soltanto il riepilogo pubblico.

-- ---------- profili ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null default '',
  gender text check (gender in ('m', 'f')),
  friend_code text unique not null default ('SIS-' || upper(substr(md5(gen_random_uuid()::text), 1, 4))),
  summary jsonb not null default '{}'::jsonb,      -- rango, livello, titolo, tratto, giorni del mese, vetrina
  updated_at timestamptz not null default now()
);

-- ---------- stato completo dell'app (solo per il proprietario) ----------
create table if not exists public.user_state (
  user_id uuid primary key references auth.users (id) on delete cascade,
  data jsonb not null,                              -- lo stesso oggetto che oggi sta nel telefono
  rev bigint not null default 0,
  updated_at timestamptz not null default now()
);

-- ---------- amicizie ----------
create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  from_id uuid not null references auth.users (id) on delete cascade,
  to_id uuid not null references auth.users (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  unique (from_id, to_id),
  check (from_id <> to_id)
);
create table if not exists public.friendships (
  user_a uuid not null references auth.users (id) on delete cascade,
  user_b uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_a, user_b),
  check (user_a < user_b)
);

-- ---------- gang ----------
create table if not exists public.gangs (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  color text not null default '#B98CFF',
  code text unique not null default ('GNG-' || upper(substr(md5(gen_random_uuid()::text), 1, 4))),
  owner_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.gang_members (
  gang_id uuid not null references public.gangs (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (gang_id, user_id)
);

-- ---------- guanti di sfida e obiettivi gang ----------
create table if not exists public.challenges (
  id uuid primary key default gen_random_uuid(),
  from_id uuid not null references auth.users (id) on delete cascade,
  to_id uuid references auth.users (id) on delete cascade,      -- null per gli obiettivi gang
  gang_id uuid references public.gangs (id) on delete cascade,  -- null per i guanti tra amici
  day date not null,
  sport text not null,
  quest text not null,
  shared boolean not null default false,
  msg text,
  reply text,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'countered', 'won', 'over', 'expired', 'open', 'passed', 'void')),
  counter jsonb,                                    -- proposta di modifica: {sport, quest, msg}
  from_done boolean not null default false,
  to_done boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((to_id is null) <> (gang_id is null))
);
create unique index if not exists challenges_one_gang_per_day on public.challenges (gang_id, day) where gang_id is not null;
create table if not exists public.challenge_members (   -- chi della gang ha accettato e chi l'ha fatto
  challenge_id uuid not null references public.challenges (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  accepted boolean,
  done boolean not null default false,
  primary key (challenge_id, user_id)
);

-- ---------- letterine e cinque ----------
create table if not exists public.letters (
  id uuid primary key default gen_random_uuid(),
  to_id uuid not null references auth.users (id) on delete cascade,
  from_id uuid references auth.users (id) on delete set null,
  kind text not null,
  title text not null,
  sub text,
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists public.fives (
  from_id uuid not null references auth.users (id) on delete cascade,
  to_id uuid not null references auth.users (id) on delete cascade,
  week date not null,                               -- lunedì della settimana: uno a settimana per amico
  primary key (from_id, to_id, week)
);

-- ---------- notifiche push (3.1) ----------
create table if not exists public.push_subscriptions (
  user_id uuid not null references auth.users (id) on delete cascade,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, endpoint)
);

-- ---------- funzioni di supporto ----------
create or replace function public.is_friend(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from friendships where user_a = least(a, b) and user_b = greatest(a, b));
$$;
create or replace function public.in_gang(g uuid, u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from gang_members where gang_id = g and user_id = u);
$$;

-- profilo creato in automatico al primo login
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id) values (new.id) on conflict do nothing;
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- accettare una richiesta crea l'amicizia (nei due versi)
create or replace function public.accept_friend(req uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r friend_requests;
begin
  select * into r from friend_requests where id = req and to_id = auth.uid() and status = 'pending';
  if not found then raise exception 'richiesta non valida'; end if;
  update friend_requests set status = 'accepted' where id = req;
  insert into friendships (user_a, user_b) values (least(r.from_id, r.to_id), greatest(r.from_id, r.to_id)) on conflict do nothing;
end; $$;

-- trovare qualcuno solo dal codice amico (nessuna ricerca per nome)
create or replace function public.profile_by_code(code text) returns table (id uuid, name text)
language sql stable security definer set search_path = public as $$
  select id, name from profiles where friend_code = upper(code);
$$;

-- entrare in una gang con il suo codice
create or replace function public.join_gang(code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare g uuid;
begin
  select id into g from gangs where gangs.code = upper(join_gang.code);
  if g is null then raise exception 'codice gang non valido'; end if;
  if (select count(*) from gang_members where gang_id = g) >= 8 then raise exception 'gang piena'; end if;
  insert into gang_members (gang_id, user_id) values (g, auth.uid()) on conflict do nothing;
  return g;
end; $$;

-- ---------- regole di accesso ----------
alter table public.profiles enable row level security;
alter table public.user_state enable row level security;
alter table public.friend_requests enable row level security;
alter table public.friendships enable row level security;
alter table public.gangs enable row level security;
alter table public.gang_members enable row level security;
alter table public.challenges enable row level security;
alter table public.challenge_members enable row level security;
alter table public.letters enable row level security;
alter table public.fives enable row level security;
alter table public.push_subscriptions enable row level security;

-- profili: io leggo e scrivo il mio; gli amici e i compagni di gang leggono il mio
drop policy if exists p_profiles_read on public.profiles;
create policy p_profiles_read on public.profiles for select using (
  id = auth.uid() or public.is_friend(id, auth.uid())
  or exists (select 1 from gang_members a join gang_members b on a.gang_id = b.gang_id where a.user_id = profiles.id and b.user_id = auth.uid())
);
drop policy if exists p_profiles_write on public.profiles;
create policy p_profiles_write on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

-- stato completo: solo io
drop policy if exists p_state_all on public.user_state;
create policy p_state_all on public.user_state for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- richieste di amicizia: le vedo se sono mie, le creo solo a mio nome
drop policy if exists p_req_read on public.friend_requests;
create policy p_req_read on public.friend_requests for select using (from_id = auth.uid() or to_id = auth.uid());
drop policy if exists p_req_insert on public.friend_requests;
create policy p_req_insert on public.friend_requests for insert with check (from_id = auth.uid());
drop policy if exists p_req_update on public.friend_requests;
create policy p_req_update on public.friend_requests for update using (to_id = auth.uid());

-- amicizie: le vedo e posso toglierle
drop policy if exists p_fr_read on public.friendships;
create policy p_fr_read on public.friendships for select using (user_a = auth.uid() or user_b = auth.uid());
drop policy if exists p_fr_delete on public.friendships;
create policy p_fr_delete on public.friendships for delete using (user_a = auth.uid() or user_b = auth.uid());

-- gang: le vedono i membri; le crea chiunque; il proprietario le modifica
drop policy if exists p_gang_read on public.gangs;
create policy p_gang_read on public.gangs for select using (owner_id = auth.uid() or public.in_gang(id, auth.uid()));
drop policy if exists p_gang_insert on public.gangs;
create policy p_gang_insert on public.gangs for insert with check (owner_id = auth.uid());
drop policy if exists p_gang_update on public.gangs;
create policy p_gang_update on public.gangs for update using (owner_id = auth.uid());
drop policy if exists p_gm_read on public.gang_members;
create policy p_gm_read on public.gang_members for select using (public.in_gang(gang_id, auth.uid()));
drop policy if exists p_gm_insert on public.gang_members;
create policy p_gm_insert on public.gang_members for insert with check (
  user_id = auth.uid() or exists (select 1 from gangs where gangs.id = gang_id and gangs.owner_id = auth.uid())
);
drop policy if exists p_gm_delete on public.gang_members;
create policy p_gm_delete on public.gang_members for delete using (user_id = auth.uid());

-- sfide: le vedono mittente, destinatario e membri della gang
drop policy if exists p_ch_read on public.challenges;
create policy p_ch_read on public.challenges for select using (
  from_id = auth.uid() or to_id = auth.uid() or (gang_id is not null and public.in_gang(gang_id, auth.uid()))
);
drop policy if exists p_ch_insert on public.challenges;
create policy p_ch_insert on public.challenges for insert with check (
  from_id = auth.uid() and (
    (to_id is not null and public.is_friend(from_id, to_id)) or (gang_id is not null and public.in_gang(gang_id, auth.uid()))
  )
);
drop policy if exists p_ch_update on public.challenges;
create policy p_ch_update on public.challenges for update using (
  from_id = auth.uid() or to_id = auth.uid() or (gang_id is not null and public.in_gang(gang_id, auth.uid()))
);
drop policy if exists p_cm_read on public.challenge_members;
create policy p_cm_read on public.challenge_members for select using (
  exists (select 1 from challenges c where c.id = challenge_id and c.gang_id is not null and public.in_gang(c.gang_id, auth.uid()))
);
drop policy if exists p_cm_write on public.challenge_members;
create policy p_cm_write on public.challenge_members for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- letterine: le leggo se sono mie; le scrivo a un amico o a un compagno di gang
drop policy if exists p_let_read on public.letters;
create policy p_let_read on public.letters for select using (to_id = auth.uid());
drop policy if exists p_let_update on public.letters;
create policy p_let_update on public.letters for update using (to_id = auth.uid());
drop policy if exists p_let_insert on public.letters;
create policy p_let_insert on public.letters for insert with check (
  from_id = auth.uid() and (public.is_friend(from_id, to_id)
    or exists (select 1 from gang_members a join gang_members b on a.gang_id = b.gang_id where a.user_id = from_id and b.user_id = to_id))
);

-- cinque: a un amico, uno a settimana (lo garantisce la chiave)
drop policy if exists p_five_read on public.fives;
create policy p_five_read on public.fives for select using (from_id = auth.uid() or to_id = auth.uid());
drop policy if exists p_five_insert on public.fives;
create policy p_five_insert on public.fives for insert with check (from_id = auth.uid() and public.is_friend(from_id, to_id));

-- push: solo le mie
drop policy if exists p_push_all on public.push_subscriptions;
create policy p_push_all on public.push_subscriptions for all using (user_id = auth.uid()) with check (user_id = auth.uid());
