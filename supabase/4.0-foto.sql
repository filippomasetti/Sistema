-- Gesta 4.0 · le foto delle sessioni
-- Una riga per foto (chi, quale sessione, giorno, se è verificata, se la vedono gli amici, se è la prova di un guanto)
-- e lo spazio file privato "foto", con le regole su chi può vedere cosa.

create table if not exists public.photos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  sess text not null,                 -- id della sessione nell'app
  day date not null,
  sport text,
  n int,                              -- numero della Gesta di quel giorno
  verified boolean not null default false,
  shared boolean not null default false,
  glove uuid references public.challenges (id) on delete set null,
  path text not null,
  created_at timestamptz not null default now(),
  unique (user_id, sess)
);
alter table public.photos enable row level security;

drop policy if exists p_ph_own on public.photos;
create policy p_ph_own on public.photos for all using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists p_ph_friends on public.photos;
create policy p_ph_friends on public.photos for select using (shared and public.is_friend(user_id, auth.uid()));
drop policy if exists p_ph_glove on public.photos;
create policy p_ph_glove on public.photos for select using (
  glove is not null and exists (select 1 from public.challenges c where c.id = glove and (c.from_id = auth.uid() or c.to_id = auth.uid()))
);

-- chi può vedere il file di una foto: tu, gli amici se l'hai condivisa, chi è nel guanto se è una prova
create or replace function public.can_see_photo(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from photos f
    where f.path = p and (
      f.user_id = auth.uid()
      or (f.shared and is_friend(f.user_id, auth.uid()))
      or (f.glove is not null and exists (select 1 from challenges c where c.id = f.glove and (c.from_id = auth.uid() or c.to_id = auth.uid())))
    )
  );
$$;

-- lo spazio file: privato, solo jpg, massimo 2 MB a foto
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('foto', 'foto', false, 2097152, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg'];

drop policy if exists "foto: carico le mie" on storage.objects;
create policy "foto: carico le mie" on storage.objects for insert to authenticated
  with check (bucket_id = 'foto' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "foto: cambio le mie" on storage.objects;
create policy "foto: cambio le mie" on storage.objects for update to authenticated
  using (bucket_id = 'foto' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "foto: tolgo le mie" on storage.objects;
create policy "foto: tolgo le mie" on storage.objects for delete to authenticated
  using (bucket_id = 'foto' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "foto: vedo" on storage.objects;
create policy "foto: vedo" on storage.objects for select to authenticated
  using (bucket_id = 'foto' and ((storage.foldername(name))[1] = auth.uid()::text or public.can_see_photo(name)));
