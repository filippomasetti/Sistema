-- Gesta 4.2 · Gesta in numeri
-- Una schermata solo per te con i totali di tutta la piattaforma: mai i dati di una persona sola.
-- Prima di premere Run cambia LA-TUA-EMAIL qui sotto (riga con insert into public.gesta_admins).

-- chi può vedere i numeri
create table if not exists public.gesta_admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);
alter table public.gesta_admins enable row level security;  -- nessuna regola: dall'app non si legge né si scrive

insert into public.gesta_admins (user_id)
select id from auth.users where lower(email) = lower('LA-TUA-EMAIL')
on conflict do nothing;

-- i giorni in cui ognuno apre Gesta (da qui in poi): serve per gli "attivi"
create table if not exists public.app_days (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  day date not null,
  primary key (user_id, day)
);
alter table public.app_days enable row level security;
drop policy if exists p_appdays_ins on public.app_days;
create policy p_appdays_ins on public.app_days for insert to authenticated with check (user_id = auth.uid());

-- l'app chiede: sono io quello che vede i numeri?
create or replace function public.is_gesta_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from gesta_admins where user_id = auth.uid());
$$;

-- i numeri, solo totali. days = 7, 30 o 0 (da sempre)
create or replace function public.gesta_numbers(days int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  since date; today date := (now() at time zone 'Europe/Rome')::date; res jsonb;
begin
  if not exists (select 1 from gesta_admins where user_id = auth.uid()) then
    raise exception 'non autorizzato';
  end if;
  since := case when coalesce(days, 0) > 0 then today - (days - 1) else date '2000-01-01' end;

  with sess as (
    select u.user_id, d.key::date as day, s.value as s
    from user_state u, jsonb_each(coalesce(u.data -> 'days', '{}'::jsonb)) d, jsonb_array_elements(d.value) s
    where d.key ~ '^\d{4}-\d{2}-\d{2}$' and jsonb_typeof(d.value) = 'array'
  ),
  per as (select * from sess where day >= since and day <= today),
  t as (
    select *, case when (s ->> 't') ~ '^\d+$' and (s ->> 't')::bigint > 0
      then to_timestamp((s ->> 't')::bigint / 1000.0) at time zone 'Europe/Rome' end as at
    from per
  ),
  opens as (
    select user_id, day from app_days
    union select user_id, day from sess
    union select user_id, (updated_at at time zone 'Europe/Rome')::date from user_state
  ),
  first_day as (select coalesce(min(day), today) as d from per),
  ch as (select * from challenges where day >= since and day <= today),
  fv as (select * from fives where week >= since - 6)
  select jsonb_build_object(
    'days', coalesce(days, 0),
    'users', (select count(*) from user_state),
    'today', (select count(distinct user_id) from opens where day = today),
    'a7', (select count(distinct user_id) from opens where day > today - 7),
    'a30', (select count(distinct user_id) from opens where day > today - 30),
    'push', (select count(distinct user_id) from push_subscriptions),
    'friends', (select count(distinct x) from (select user_a as x from friendships union select user_b from friendships) f),
    'daily', (select coalesce(jsonb_agg(n order by g), '[]'::jsonb) from (
        select g, (select count(distinct user_id) from opens o where o.day = g::date) as n
        from generate_series(today - 29, today, interval '1 day') g) z),
    'sessions', (select count(*) from per),
    'sdays', (select count(distinct (user_id, day)) from per),
    'people', (select count(distinct user_id) from per),
    'weeks', greatest(1, (today - (select d from first_day) + 1) / 7.0),
    'sports', (select coalesce(jsonb_object_agg(sp, n), '{}'::jsonb) from (select s ->> 'sport' as sp, count(*) as n from per group by 1) z),
    'hours', (select jsonb_build_object(
        'm', count(*) filter (where extract(hour from at) < 13),
        'p', count(*) filter (where extract(hour from at) >= 13 and extract(hour from at) < 18),
        's', count(*) filter (where extract(hour from at) >= 18),
        'same', count(*) filter (where at::date = day),
        'late', count(*) filter (where at::date > day)) from t where at is not null),
    'quests', (select coalesce(jsonb_object_agg(df, jsonb_build_object('n', n, 'ok', ok)), '{}'::jsonb) from (
        select s -> 'quest' ->> 'diff' as df, count(*) as n, count(*) filter (where s -> 'quest' ->> 'done' = 'true') as ok
        from per where s ? 'quest' and s -> 'quest' ->> 'done' in ('true', 'false') group by 1) z),
    'faces', (select coalesce(jsonb_object_agg(f, n), '{}'::jsonb) from (select s -> 'd' ->> 'face' as f, count(*) as n from per where s -> 'd' ->> 'face' in ('r', 'y', 'g') group by 1) z),
    'stars', (select count(*) from per where s ->> 'star' = 'true'),
    'photos', (select jsonb_build_object('n', count(*) filter (where s ? 'ph'),
        'v', count(*) filter (where s -> 'ph' ->> 'v' in ('1', 'true')),
        'sh', count(*) filter (where s -> 'ph' ->> 'sh' in ('1', 'true'))) from per),
    'when', (select jsonb_build_object('d', count(*) filter (where x = 'd'), 's', count(*) filter (where x = 's'))
        from user_state u, jsonb_array_elements_text(case when jsonb_typeof(u.data -> 'wl') = 'array' then u.data -> 'wl' else '[]'::jsonb end) x),
    'plans', (select jsonb_build_object('n', count(*), 'who', count(distinct u.user_id))
        from user_state u, jsonb_object_keys(case when jsonb_typeof(u.data -> 'plan') = 'object' then u.data -> 'plan' else '{}'::jsonb end) k
        where k ~ '^\d{4}-\d{2}-\d{2}$' and k::date >= today),
    'gloves', (select jsonb_build_object('n', count(*), 'acc', count(*) filter (where status in ('accepted', 'won', 'over')),
        'won', count(*) filter (where status = 'won'), 'lost', count(*) filter (where status = 'over')) from ch where gang_id is null),
    'gangs', (select count(*) from gangs),
    'gpass', (select count(*) from ch where gang_id is not null and status = 'passed'),
    'fives', (select count(*) from fv where week >= since - 6 and week <= today),
    'fbat', (select count(*) from fv a where a.from_id < a.to_id and exists (
        select 1 from fv b where b.from_id = a.to_id and b.to_id = a.from_id and b.week between a.week - 7 and a.week + 7)),
    'ranks', (select coalesce(jsonb_object_agg(r, n), '{}'::jsonb) from (
        select summary ->> 'rank' as r, count(*) as n from profiles
        where summary ->> 'ym' = to_char(today, 'YYYY-MM') and summary ? 'rank' group by 1) z)
  ) into res;
  return res;
end;
$$;

revoke all on function public.gesta_numbers(int) from public, anon;
grant execute on function public.gesta_numbers(int) to authenticated;
revoke all on function public.is_gesta_admin() from public, anon;
grant execute on function public.is_gesta_admin() to authenticated;
