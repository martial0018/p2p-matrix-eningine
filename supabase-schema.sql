create type public.app_role as enum ('buyer', 'seller', 'arbiter', 'moderator', 'admin');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'New user',
  role public.app_role not null default 'buyer',
  created_at timestamptz not null default now()
);

create table public.simulation_snapshots (
  user_id uuid primary key references auth.users(id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table public.simulation_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  day integer not null default 0,
  event_type text not null,
  message text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.simulation_orders (
  id text primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  order_data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table public.simulation_control (
  id boolean primary key default true check (id = true),
  playing boolean not null default false,
  speed integer not null default 1200,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into public.simulation_control (id)
values (true)
on conflict (id) do nothing;

alter table public.simulation_snapshots enable row level security;
alter table public.simulation_events enable row level security;
alter table public.simulation_orders enable row level security;
alter table public.simulation_control enable row level security;

create policy "Users manage own snapshot"
on public.simulation_snapshots for all
using (user_id = auth.uid())
with check (user_id = auth.uid());

create policy "Users read own events"
on public.simulation_events for select
using (user_id = auth.uid());

create policy "Users create own events"
on public.simulation_events for insert
with check (user_id = auth.uid());

create index simulation_events_user_created_idx
on public.simulation_events (user_id, created_at desc);

alter table public.profiles enable row level security;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

create policy "Authenticated users read simulation control"
on public.simulation_control for select
using (auth.uid() is not null);

create policy "Admins update simulation control"
on public.simulation_control for update
using (public.is_admin())
with check (public.is_admin());

create policy "Users and review roles read orders"
on public.simulation_orders for select
using (
  owner_id = auth.uid()
  or public.is_admin()
  or exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('arbiter', 'moderator')
  )
);

create policy "Users create own orders"
on public.simulation_orders for insert
with check (owner_id = auth.uid() or public.is_admin());

create policy "Users update own orders and admins update all"
on public.simulation_orders for update
using (owner_id = auth.uid() or public.is_admin())
with check (owner_id = auth.uid() or public.is_admin());

create index simulation_orders_owner_updated_idx
on public.simulation_orders (owner_id, updated_at desc);

create policy "Users read own profile"
on public.profiles for select
using (id = auth.uid() or public.is_admin());

create policy "Admins manage profiles"
on public.profiles for update
using (public.is_admin())
with check (public.is_admin());

create policy "Users create own profile"
on public.profiles for insert
with check (id = auth.uid());

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', 'New user'));
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- Promote the first account manually after signup:
-- update public.profiles set role = 'admin' where id = 'USER_UUID';
