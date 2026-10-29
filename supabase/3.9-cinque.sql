-- Gesta 3.9 · il cinque su una sessione precisa: giorno e sport
alter table public.fives add column if not exists day date;
alter table public.fives add column if not exists sport text;
