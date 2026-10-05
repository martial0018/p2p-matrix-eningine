create type public.app_role as enum ('buyer', 'seller', 'arbiter', 'moderator', 'admin');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'New user',
  role public.app_role not null default 'buyer',
  moderator_previous_role public.app_role,
  arbiter_previous_role public.app_role,
  created_at timestamptz not null default now()
);

alter table public.profiles
  add column if not exists moderator_previous_role public.app_role,
  add column if not exists arbiter_previous_role public.app_role;

create table public.profile_contacts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  phone text
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
  day integer not null default 0,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.simulation_control
  add column if not exists day integer not null default 0;

create table public.simulation_queue (
  id text primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  queue_data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create or replace function public.preserve_resolved_simulation_status()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  old_status text;
  new_status text;
begin
  if tg_table_name = 'simulation_orders' then
    old_status := old.order_data ->> 'status';
    new_status := new.order_data ->> 'status';
    if old_status in ('HOLDING', 'QUEUE', 'TRANSFERRED', 'SETTLED')
       and new_status in ('PAIRED', 'PROOF', 'FLAGGED', 'PARTIAL', 'UNMATCHED') then
      new.order_data := jsonb_set(new.order_data, '{status}', to_jsonb(old_status), true);
      if old.order_data ? 'unlockedDay' then
        new.order_data := jsonb_set(new.order_data, '{unlockedDay}', old.order_data -> 'unlockedDay', true);
      end if;
    end if;
  elsif tg_table_name = 'simulation_queue'
        and old.queue_data ->> 'status' = 'SETTLED'
        and new.queue_data ->> 'status' in ('MATCHED', 'WAITING') then
    new.queue_data := jsonb_set(new.queue_data, '{status}', '"SETTLED"'::jsonb, true);
    if old.queue_data ? 'settledAt' then
      new.queue_data := jsonb_set(new.queue_data, '{settledAt}', old.queue_data -> 'settledAt', true);
    end if;
  end if;
  return new;
end;
$$;

create trigger preserve_resolved_simulation_order_status
before update of order_data on public.simulation_orders
for each row execute function public.preserve_resolved_simulation_status();

create or replace function public.prevent_buyer_matching_own_seller_offer()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  previous_match_ids text[] := array[]::text[];
  previous_order_status text;
begin
  if coalesce(new.order_data ->> 'status', '') not in ('PAIRED', 'PARTIAL', 'PROOF', 'FLAGGED', 'HOLDING') then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and old.order_data ->> 'status' in ('PAIRED', 'PARTIAL', 'PROOF', 'FLAGGED', 'HOLDING') then
    previous_order_status := old.order_data ->> 'status';
    select coalesce(array_agg(match_id), array[]::text[])
    into previous_match_ids
    from (
      select leg ->> 'id' as match_id
      from jsonb_array_elements(
        case when jsonb_typeof(old.order_data -> 'legs') = 'array'
          then old.order_data -> 'legs' else '[]'::jsonb end
      ) leg
      union
      select old.order_data -> 'matchObj' ->> 'id'
    ) previous_matches
    where match_id is not null;
  end if;

  if new.owner_id is not null and exists (
    select 1
    from public.simulation_queue seller_entry
    where seller_entry.owner_id = new.owner_id
      and seller_entry.id in (
        select leg ->> 'id'
        from jsonb_array_elements(
          case when jsonb_typeof(new.order_data -> 'legs') = 'array'
            then new.order_data -> 'legs' else '[]'::jsonb end
        ) leg
        union
        select new.order_data -> 'matchObj' ->> 'id'
      )
      and (
        not (seller_entry.id = any(previous_match_ids))
        or (
          previous_order_status is distinct from new.order_data ->> 'status'
          and new.order_data ->> 'status' in ('PROOF', 'HOLDING')
        )
      )
  ) then
    raise exception using
      errcode = '23514',
      message = 'A buyer cannot match their own seller offer.';
  end if;

  return new;
end;
$$;

create trigger zz_prevent_buyer_matching_own_seller_offer
before insert or update on public.simulation_orders
for each row execute function public.prevent_buyer_matching_own_seller_offer();

create or replace function public.enforce_one_active_bid_per_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.order_data ->> 'status' not in ('UNMATCHED', 'PARTIAL', 'PAIRED', 'PROOF', 'FLAGGED') then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and old.owner_id = new.owner_id
     and old.order_data ->> 'status' in ('UNMATCHED', 'PARTIAL', 'PAIRED', 'PROOF', 'FLAGGED') then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(new.owner_id::text, 0));

  if exists (
    select 1
    from public.simulation_orders existing_order
    where existing_order.owner_id = new.owner_id
      and existing_order.id <> new.id
      and existing_order.order_data ->> 'status' in ('UNMATCHED', 'PARTIAL', 'PAIRED', 'PROOF', 'FLAGGED')
  ) then
    raise exception using
      errcode = '23505',
      message = 'Only one active bid per user is allowed. Finish or cancel the current bid before placing another.';
  end if;

  return new;
end;
$$;

create trigger zz_enforce_one_active_bid_per_user
before insert or update on public.simulation_orders
for each row execute function public.enforce_one_active_bid_per_user();

create trigger preserve_resolved_simulation_queue_status
before update of queue_data on public.simulation_queue
for each row execute function public.preserve_resolved_simulation_status();

insert into public.simulation_control (id)
values (true)
on conflict (id) do nothing;

alter table public.simulation_snapshots enable row level security;
alter table public.simulation_events enable row level security;
alter table public.simulation_orders enable row level security;
alter table public.simulation_control enable row level security;
alter table public.simulation_queue enable row level security;

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
alter table public.profile_contacts enable row level security;

create policy "Users read own profile contact"
on public.profile_contacts for select
using (user_id = auth.uid());

revoke all on public.profile_contacts from anon, authenticated;
grant select on public.profile_contacts to authenticated;

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

create or replace function public.is_review_role()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('arbiter', 'moderator')
  );
$$;

create policy "Authenticated users read simulation control"
on public.simulation_control for select
using (auth.uid() is not null);

create policy "Admins update simulation control"
on public.simulation_control for update
using (public.is_admin())
with check (public.is_admin());

create policy "Admins insert simulation control"
on public.simulation_control for insert
with check (public.is_admin());

create policy "Owners read own queue"
on public.simulation_queue for select
using (owner_id = auth.uid());

create policy "Review roles read all queue"
on public.simulation_queue for select
using (public.is_review_role() or public.is_admin());

create policy "Users create own queue entries"
on public.simulation_queue for insert
with check (owner_id = auth.uid() or public.is_admin());

create policy "Owners and admins update queue entries"
on public.simulation_queue for update
using (owner_id = auth.uid() or public.is_admin())
with check (owner_id = auth.uid() or public.is_admin());

create index simulation_queue_owner_updated_idx
on public.simulation_queue (owner_id, updated_at desc);

create policy "Owners read own orders"
on public.simulation_orders for select
using (owner_id = auth.uid());

drop policy if exists "Review roles read all orders" on public.simulation_orders;
create policy "Review roles read all orders"
on public.simulation_orders for select
using (public.is_review_role() or public.is_admin());

create or replace function public.arbiter_resolve_simulation_order(
  p_order_id text,
  p_decision text,
  p_day integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_order jsonb;
  next_status text;
begin
  if auth.uid() is null or not (public.is_review_role() or public.is_admin()) then
    raise exception 'Arbiter, moderator, or admin access required';
  end if;

  if p_decision not in ('APPROVE', 'REJECT') then
    raise exception 'Decision must be APPROVE or REJECT';
  end if;

  select order_data into current_order
  from public.simulation_orders
  where id = p_order_id
  for update;

  if current_order is null then
    raise exception 'Order not found';
  end if;
  if current_order ->> 'status' not in ('FLAGGED', 'PROOF', 'PAIRED') then
    raise exception 'Order is already resolved or is not awaiting review';
  end if;

  next_status := case when p_decision = 'APPROVE' then 'HOLDING' else 'CANCELLED' end;
  current_order := jsonb_set(current_order, '{status}', to_jsonb(next_status), true);
  if p_decision = 'APPROVE' then
    current_order := jsonb_set(current_order, '{unlockedDay}', to_jsonb(coalesce(p_day, 0)), true);
  end if;

  update public.simulation_orders
  set order_data = current_order, updated_at = now()
  where id = p_order_id;

  if p_decision = 'APPROVE' then
    update public.simulation_queue q
    set queue_data = jsonb_set(
          jsonb_set(q.queue_data, '{status}', '"SETTLED"'::jsonb),
          '{settledAt}', to_jsonb(now()), true
        ),
        updated_at = now()
    where q.queue_data ->> 'status' = 'MATCHED'
      and coalesce(q.queue_data ->> 'matchedBuyerOrderId', q.queue_data ->> 'matchedOrderId') = p_order_id;
  else
    update public.simulation_queue q
    set queue_data = (q.queue_data - 'matchedOrderId' - 'matchedBuyerOrderId' - 'matchedBuyerOwnerId' - 'matchedBuyerName')
                     || '{"status":"WAITING"}'::jsonb,
        updated_at = now()
    where q.queue_data ->> 'status' = 'MATCHED'
      and coalesce(q.queue_data ->> 'matchedBuyerOrderId', q.queue_data ->> 'matchedOrderId') = p_order_id;
  end if;

  return jsonb_build_object('order_id', p_order_id, 'status', next_status);
end;
$$;

revoke all on function public.arbiter_resolve_simulation_order(text, text, integer) from public;
grant execute on function public.arbiter_resolve_simulation_order(text, text, integer) to authenticated;

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

create or replace function public.admin_promote_moderator(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_role public.app_role;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  select role into target_role
  from public.profiles
  where id = p_user_id
  for update;

  if not found then
    raise exception 'Profile not found';
  end if;
  if target_role not in ('buyer', 'seller') then
    raise exception 'Only buyer or seller profiles can be promoted';
  end if;

  update public.profiles
  set moderator_previous_role = target_role,
      role = 'moderator'
  where id = p_user_id;
end;
$$;

create or replace function public.admin_demote_moderator(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_role public.app_role;
  previous_role public.app_role;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  select role, moderator_previous_role into target_role, previous_role
  from public.profiles
  where id = p_user_id
  for update;

  if not found then
    raise exception 'Profile not found';
  end if;
  if target_role <> 'moderator' then
    raise exception 'Profile is not a moderator';
  end if;
  if previous_role is null then
    raise exception 'Previous role is unknown; set moderator_previous_role before demoting this profile';
  end if;

  update public.profiles
  set role = previous_role,
      moderator_previous_role = null
  where id = p_user_id;
end;
$$;

revoke all on function public.admin_promote_moderator(uuid) from public, anon;
grant execute on function public.admin_promote_moderator(uuid) to authenticated;
revoke all on function public.admin_demote_moderator(uuid) from public, anon;
grant execute on function public.admin_demote_moderator(uuid) to authenticated;

create or replace function public.admin_promote_arbiter(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_role public.app_role;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  select role into target_role
  from public.profiles
  where id = p_user_id
  for update;

  if not found then
    raise exception 'Profile not found';
  end if;
  if target_role not in ('buyer', 'seller') then
    raise exception 'Only buyer or seller profiles can be promoted to arbiter';
  end if;

  update public.profiles
  set arbiter_previous_role = target_role,
      role = 'arbiter'
  where id = p_user_id;
end;
$$;

create or replace function public.admin_demote_arbiter(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_role public.app_role;
  previous_role public.app_role;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  select role, arbiter_previous_role into target_role, previous_role
  from public.profiles
  where id = p_user_id
  for update;

  if not found then
    raise exception 'Profile not found';
  end if;
  if target_role <> 'arbiter' then
    raise exception 'Profile is not an arbiter';
  end if;
  if previous_role is null then
    raise exception 'Previous role is unknown; set arbiter_previous_role before demoting this profile';
  end if;

  update public.profiles
  set role = previous_role,
      arbiter_previous_role = null
  where id = p_user_id;
end;
$$;

revoke all on function public.admin_promote_arbiter(uuid) from public, anon;
grant execute on function public.admin_promote_arbiter(uuid) to authenticated;
revoke all on function public.admin_demote_arbiter(uuid) from public, anon;
grant execute on function public.admin_demote_arbiter(uuid) to authenticated;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'display_name', 'New user')
  );
  insert into public.profile_contacts (user_id, phone)
  values (
    new.id,
    nullif(btrim(new.raw_user_meta_data ->> 'phone'), '')
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- Promote the first account manually after signup:
-- update public.profiles set role = 'admin' where id = 'USER_UUID';
