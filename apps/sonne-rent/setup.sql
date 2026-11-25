-- Sonne Rent — إعداد قاعدة البيانات في Supabase
-- شغّل هذا الملف مرة واحدة: Supabase ← SQL Editor ← New query ← الصق ← Run

create table if not exists public.rent_records (
  coll text not null,
  id text not null,
  data jsonb not null default '{}'::jsonb,
  deleted boolean not null default false,
  updated_at timestamptz not null default clock_timestamp(),
  primary key (coll, id)
);
create index if not exists rent_records_updated on public.rent_records (updated_at);

create or replace function public.rent_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end $$;

drop trigger if exists rent_touch on public.rent_records;
create trigger rent_touch before insert or update on public.rent_records
for each row execute function public.rent_touch();

alter table public.rent_records enable row level security;

drop policy if exists rent_staff_all on public.rent_records;
create policy rent_staff_all on public.rent_records
  for all to authenticated using (true) with check (true);

-- الزوار (صفحة العملاء): يقرؤون السيارات والإعدادات فقط
drop policy if exists rent_public_read on public.rent_records;
create policy rent_public_read on public.rent_records
  for select to anon using (coll in ('cars','settings') and deleted = false);

-- الزوار: يرسلون طلبات الحجز وبلاغات الحوادث فقط (بدون تعديل أو حذف)
drop policy if exists rent_public_request on public.rent_records;
create policy rent_public_request on public.rent_records
  for insert to anon with check (coll = 'requests' and deleted = false);

-- ترقيم متسلسل للحجوزات والفواتير (بدون تكرار حتى مع عدة موظفين)
create table if not exists public.rent_counters (k text primary key, v integer not null default 0);
alter table public.rent_counters enable row level security;

create or replace function public.rent_next_no(p_k text) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if auth.role() <> 'authenticated' then raise exception 'not allowed'; end if;
  insert into rent_counters (k, v) values (p_k, 1)
  on conflict (k) do update set v = rent_counters.v + 1
  returning v into n;
  return n;
end $$;

create or replace function public.rent_set_no(p_k text, p_n integer) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.role() <> 'authenticated' then raise exception 'not allowed'; end if;
  insert into rent_counters (k, v) values (p_k, p_n)
  on conflict (k) do update set v = greatest(rent_counters.v, p_n);
end $$;

-- فحص توفر السيارة لصفحة العملاء (يعيد التواريخ فقط، بدون بيانات العملاء)
create or replace function public.rent_busy(car text) returns table (s text, e text)
language sql security definer set search_path = public as $$
  select data->>'start', data->>'end'
  from rent_records
  where coll = 'bookings' and deleted = false
    and data->>'carId' = car
    and data->>'status' in ('new','confirmed','active');
$$;

revoke execute on function public.rent_next_no(text) from anon;
revoke execute on function public.rent_set_no(text, integer) from anon;
grant execute on function public.rent_busy(text) to anon, authenticated;
