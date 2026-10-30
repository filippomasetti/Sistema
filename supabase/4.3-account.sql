-- Gesta 4.3 · cancellare il proprio account e "Segnala un problema"
-- Niente da cambiare: incolla tutto e premi Run.

-- 1. cancellare l'account. Le foto le toglie prima l'app; qui si cancella l'utente
--    e, a cascata, profilo, dati salvati, amicizie, guanti, cinque, letterine, notifiche, foto, Gang create.
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'non autorizzato'; end if;
  delete from auth.users where id = me;
end;
$$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- 2. le segnalazioni: le scrive chiunque abbia l'app, le legge solo chi è in gesta_admins
create table if not exists public.feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid default auth.uid() references auth.users (id) on delete set null,
  msg text not null check (char_length(msg) between 1 and 1500),
  ver text check (char_length(ver) <= 40),
  device text check (char_length(device) <= 200),
  created_at timestamptz not null default now()
);
alter table public.feedback enable row level security;
drop policy if exists p_fb_ins on public.feedback;
create policy p_fb_ins on public.feedback for insert to anon, authenticated
  with check (user_id is null or user_id = auth.uid());

create or replace function public.gesta_feedback() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from gesta_admins where user_id = auth.uid()) then
    raise exception 'non autorizzato';
  end if;
  return (select coalesce(jsonb_agg(x order by x.at desc), '[]'::jsonb) from (
    select f.msg, f.ver, f.device, f.created_at as at, coalesce(nullif(p.name, ''), 'Senza nome') as name
    from feedback f left join profiles p on p.id = f.user_id
    order by f.created_at desc limit 50) x);
end;
$$;
revoke all on function public.gesta_feedback() from public, anon;
grant execute on function public.gesta_feedback() to authenticated;
