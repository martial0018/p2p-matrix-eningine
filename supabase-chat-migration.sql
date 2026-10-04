create table if not exists public.simulation_messages (
  id uuid primary key default gen_random_uuid(),
  order_id text not null references public.simulation_orders(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  created_at timestamptz not null default now()
);

create index if not exists simulation_messages_order_created_idx
on public.simulation_messages (order_id, created_at);

alter table public.simulation_messages enable row level security;

create or replace function public.is_simulation_chat_participant(target_order_id text, target_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.simulation_orders o
    where o.id = target_order_id and o.owner_id = target_user_id
  ) or exists (
    select 1
    from public.simulation_queue q
    where q.owner_id = target_user_id
      and coalesce(q.queue_data ->> 'matchedBuyerOrderId', q.queue_data ->> 'matchedOrderId') = target_order_id
  );
$$;

revoke all on function public.is_simulation_chat_participant(text, uuid) from public;
grant execute on function public.is_simulation_chat_participant(text, uuid) to authenticated;

drop policy if exists "Trade participants and admins read messages" on public.simulation_messages;
create policy "Trade participants and admins read messages"
on public.simulation_messages for select
using (
  public.is_admin()
  or sender_id = auth.uid()
  or recipient_id = auth.uid()
);

drop policy if exists "Matched participants send messages" on public.simulation_messages;
create policy "Matched participants send messages"
on public.simulation_messages for insert
with check (
  sender_id = auth.uid()
  and sender_id <> recipient_id
  and public.is_simulation_chat_participant(order_id, sender_id)
  and public.is_simulation_chat_participant(order_id, recipient_id)
);

grant select, insert on public.simulation_messages to authenticated;

create or replace function public.is_active_simulation_seller_offer(
  target_queue_data jsonb,
  target_owner_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
  coalesce(nullif(target_queue_data ->> 'amount', ''), '0')::numeric >= 0.01
  and (
    target_queue_data ->> 'maturedSeller' is distinct from 'true'
    or target_queue_data ->> 'saleRequested' = 'true'
    or exists (
      select 1
      from public.simulation_orders source_order
      where source_order.id = target_queue_data ->> 'sourceOrderId'
        and source_order.owner_id = target_owner_id
        and source_order.order_data ->> 'status' = 'QUEUE'
    )
  );
$$;

revoke all on function public.is_active_simulation_seller_offer(jsonb, uuid) from public;
grant execute on function public.is_active_simulation_seller_offer(jsonb, uuid) to authenticated;

drop policy if exists "Authenticated users read active seller offers" on public.simulation_queue;
create policy "Authenticated users read active seller offers"
on public.simulation_queue for select
using (
  auth.uid() is not null
  and queue_data ->> 'status' = 'WAITING'
  and public.is_active_simulation_seller_offer(queue_data, owner_id)
);

drop policy if exists "Matched buyers read linked seller entries" on public.simulation_queue;
create policy "Matched buyers read linked seller entries"
on public.simulation_queue for select
using (
  queue_data ->> 'status' in ('MATCHED', 'SETTLED')
  and public.is_simulation_chat_participant(
    coalesce(queue_data ->> 'matchedBuyerOrderId', queue_data ->> 'matchedOrderId'),
    auth.uid()
  )
);

create or replace function public.is_review_role()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid() and role in ('arbiter', 'moderator')
  );
$$;

revoke all on function public.is_review_role() from public;
grant execute on function public.is_review_role() to authenticated;

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

  select order_data
  into current_order
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
  set order_data = current_order,
      updated_at = now()
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

create table if not exists public.profile_contacts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  phone text
);

alter table public.profile_contacts enable row level security;

drop policy if exists "Users read own profile contact" on public.profile_contacts;
create policy "Users read own profile contact"
on public.profile_contacts for select
using (user_id = auth.uid());

revoke all on public.profile_contacts from anon, authenticated;
grant select on public.profile_contacts to authenticated;

insert into public.profile_contacts (user_id, phone)
select u.id, nullif(btrim(u.raw_user_meta_data ->> 'phone'), '')
from auth.users u
on conflict (user_id) do nothing;

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

create or replace function public.update_my_profile(p_display_name text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_name text := btrim(coalesce(p_display_name, ''));
  clean_phone text := nullif(btrim(coalesce(p_phone, '')), '');
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if char_length(clean_name) not between 1 and 80 then
    raise exception 'Name must be between 1 and 80 characters';
  end if;

  if clean_phone is not null
     and regexp_replace(clean_phone, '[[:space:]()-]', '', 'g') !~ '^\+?[0-9]{7,15}$' then
    raise exception 'Enter a valid phone number';
  end if;

  update public.profiles
  set display_name = clean_name
  where id = auth.uid();

  if not found then
    raise exception 'Profile not found';
  end if;

  insert into public.profile_contacts (user_id, phone)
  values (auth.uid(), clean_phone)
  on conflict (user_id) do update set phone = excluded.phone;

  return jsonb_build_object('display_name', clean_name, 'phone', clean_phone);
end;
$$;

revoke all on function public.update_my_profile(text, text) from public;
grant execute on function public.update_my_profile(text, text) to authenticated;

drop policy if exists "Admins insert simulation control" on public.simulation_control;
create policy "Admins insert simulation control"
on public.simulation_control for insert
with check (public.is_admin());

insert into public.simulation_control (id)
values (true)
on conflict (id) do nothing;

create or replace function public.buyer_match_simulation_queue_entry(
  p_order_id text,
  p_queue_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  buyer_order_data jsonb;
  buyer_order_owner_id uuid;
  seller_entry public.simulation_queue%rowtype;
  matched_amount numeric;
  residual_amount numeric;
  residual_id text;
  residual_data jsonb;
  existing_order_id text;
  existing_order_owner_id uuid;
  existing_order_status text;
  existing_order_unlocked_day integer;
  seller_already_settled boolean := false;
  seller_sale_key text;
  matched_buyer_order_count integer := 0;
  buyer_order_already_counted boolean := false;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select order_data, owner_id
  into buyer_order_data, buyer_order_owner_id
  from public.simulation_orders
  where id = p_order_id
  for update;

  if buyer_order_data is null or buyer_order_owner_id <> auth.uid() then
    raise exception 'Buyer order not found';
  end if;
  select *
  into seller_entry
  from public.simulation_queue
  where id = p_queue_id
  for update;

  if seller_entry.id is null or seller_entry.owner_id = auth.uid() then
    raise exception 'Seller queue entry not found';
  end if;
  seller_sale_key := coalesce(seller_entry.queue_data ->> 'sourceOrderId', seller_entry.id);
  perform pg_advisory_xact_lock(
    hashtext(seller_entry.owner_id::text),
    hashtext(seller_sale_key)
  );
  seller_already_settled := seller_entry.queue_data ->> 'status' = 'SETTLED';
  if coalesce(buyer_order_data ->> 'status', '') not in ('PAIRED', 'PARTIAL', 'PROOF', 'FLAGGED')
     and not (seller_already_settled and buyer_order_data ->> 'status' = 'HOLDING') then
    raise exception 'Buyer order is not awaiting seller settlement';
  end if;

  if seller_entry.queue_data ->> 'status' not in ('WAITING', 'MATCHED', 'SETTLED') then
    raise exception 'Seller queue entry is not available';
  end if;
  select count(distinct coalesce(
           q.queue_data ->> 'matchedBuyerOrderId',
           q.queue_data ->> 'matchedOrderId'
         )),
         coalesce(bool_or(coalesce(
           q.queue_data ->> 'matchedBuyerOrderId',
           q.queue_data ->> 'matchedOrderId'
         ) = p_order_id), false)
  into matched_buyer_order_count, buyer_order_already_counted
  from public.simulation_queue q
  where q.owner_id = seller_entry.owner_id
    and coalesce(q.queue_data ->> 'sourceOrderId', q.id) = seller_sale_key
    and q.id <> p_queue_id
    and q.queue_data ->> 'status' in ('MATCHED', 'SETTLED')
    and coalesce(q.queue_data ->> 'matchedBuyerOrderId', q.queue_data ->> 'matchedOrderId') is not null;
  if matched_buyer_order_count >= 2 and not buyer_order_already_counted then
    raise exception 'Seller sale is limited to two buyer orders';
  end if;
  if seller_entry.queue_data ->> 'status' in ('MATCHED', 'SETTLED') then
    existing_order_id := coalesce(
      seller_entry.queue_data ->> 'matchedBuyerOrderId',
      seller_entry.queue_data ->> 'matchedOrderId'
    );
    if existing_order_id = p_order_id then
      existing_order_owner_id := buyer_order_owner_id;
      existing_order_status := buyer_order_data ->> 'status';
    else
      select owner_id, order_data ->> 'status',
             nullif(order_data ->> 'unlockedDay', '')::integer
      into existing_order_owner_id, existing_order_status, existing_order_unlocked_day
      from public.simulation_orders
      where id = existing_order_id;
    end if;
    if existing_order_owner_id is distinct from auth.uid()
       or (
         existing_order_status not in ('PAIRED', 'PARTIAL', 'PROOF', 'FLAGGED')
         and not (seller_already_settled and existing_order_status = 'HOLDING')
       ) then
      raise exception 'Seller queue entry is already linked to a settled or unrelated order';
    end if;
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(
      case when jsonb_typeof(buyer_order_data -> 'legs') = 'array'
        then buyer_order_data -> 'legs' else '[]'::jsonb end
    ) leg
    where leg ->> 'id' = p_queue_id
  ) and coalesce(buyer_order_data -> 'matchObj' ->> 'id', '') <> p_queue_id then
    raise exception 'Seller entry is not part of this buyer order';
  end if;

  if seller_entry.queue_data ->> 'maturedSeller' = 'true'
     and seller_entry.queue_data ->> 'saleRequested' is distinct from 'true'
     and not exists (
       select 1
       from public.simulation_orders source_order
       where source_order.id = seller_entry.queue_data ->> 'sourceOrderId'
         and source_order.owner_id = seller_entry.owner_id
         and source_order.order_data ->> 'status' = 'QUEUE'
     ) then
    raise exception 'Seller has not requested a sale';
  end if;

  select (leg ->> 'fill')::numeric
  into matched_amount
  from jsonb_array_elements(
    case when jsonb_typeof(buyer_order_data -> 'legs') = 'array'
      then buyer_order_data -> 'legs' else '[]'::jsonb end
  ) leg
  where leg ->> 'id' = p_queue_id
  limit 1;

  if matched_amount is null then
    matched_amount := least(
      coalesce(nullif(seller_entry.queue_data ->> 'amount', '')::numeric, 0),
      coalesce(nullif(buyer_order_data ->> 'transferAmt', '')::numeric,
               nullif(buyer_order_data ->> 'principal', '')::numeric, 0)
    );
  end if;
  if matched_amount <= 0
     or matched_amount > coalesce(nullif(seller_entry.queue_data ->> 'amount', '')::numeric, 0) + 0.5
     or matched_amount > coalesce(nullif(buyer_order_data ->> 'principal', '')::numeric, 0) then
    raise exception 'Invalid seller match amount';
  end if;
  if matched_buyer_order_count = 1
     and not buyer_order_already_counted
     and seller_entry.queue_data ->> 'status' = 'WAITING'
     and (
       matched_amount + 0.001 < coalesce(nullif(seller_entry.queue_data ->> 'amount', '')::numeric, 0)
       or exists (
         select 1
         from public.simulation_queue q
         where q.owner_id = seller_entry.owner_id
           and coalesce(q.queue_data ->> 'sourceOrderId', q.id) = seller_sale_key
           and q.queue_data ->> 'status' = 'WAITING'
           and q.id <> p_queue_id
       )
     ) then
    raise exception 'The second buyer order must take the entire remaining seller sale';
  end if;

  residual_amount := greatest(
    0,
    coalesce(nullif(seller_entry.queue_data ->> 'amount', '')::numeric, 0) - matched_amount
  );
  update public.simulation_queue
  set queue_data = seller_entry.queue_data
        || jsonb_build_object(
             'status', case when seller_already_settled then 'SETTLED' else 'MATCHED' end,
             'amount', matched_amount,
             'matchedAmount', matched_amount,
             'matchedOrderId', p_order_id,
             'matchedBuyerOrderId', p_order_id,
             'matchedBuyerOwnerId', buyer_order_owner_id,
             'matchedBuyerName', coalesce(buyer_order_data ->> 'buyer_name', 'Buyer')
           ),
      updated_at = now()
  where id = p_queue_id;

  if seller_already_settled and buyer_order_data ->> 'status' <> 'HOLDING' then
    update public.simulation_orders
    set order_data = jsonb_set(
          jsonb_set(buyer_order_data, '{status}', '"HOLDING"'::jsonb, true),
          '{unlockedDay}', to_jsonb(coalesce(existing_order_unlocked_day, 0)), true
        ),
        updated_at = now()
    where id = p_order_id;
  end if;

  if residual_amount >= 0.01 then
    select id
    into residual_id
    from public.simulation_queue
    where owner_id = seller_entry.owner_id
      and left(id, length(p_queue_id) + 3) = p_queue_id || '-R-'
      and queue_data ->> 'status' = 'WAITING'
    order by updated_at desc
    limit 1
    for update;

    if residual_id is null then
      residual_id := p_queue_id || '-R-' || substr(md5(p_order_id), 1, 8);
      residual_data := (seller_entry.queue_data
          - 'matchedOrderId' - 'matchedBuyerOrderId' - 'matchedBuyerOwnerId'
          - 'matchedBuyerName' - 'matchedAmount')
        || jsonb_build_object('id', residual_id, 'amount', residual_amount, 'status', 'WAITING');
      insert into public.simulation_queue (id, owner_id, queue_data, updated_at)
      values (residual_id, seller_entry.owner_id, residual_data, now())
      on conflict (id) do nothing;
    else
      update public.simulation_queue
      set queue_data = queue_data || jsonb_build_object('amount', residual_amount, 'status', 'WAITING'),
          updated_at = now()
      where id = residual_id;

      delete from public.simulation_queue
      where owner_id = seller_entry.owner_id
        and left(id, length(p_queue_id) + 3) = p_queue_id || '-R-'
        and queue_data ->> 'status' = 'WAITING'
        and id <> residual_id;
    end if;
  end if;

  return jsonb_build_object(
    'order_id', p_order_id,
    'queue_id', p_queue_id,
    'status', case when seller_already_settled then 'SETTLED' else 'MATCHED' end,
    'matched_amount', matched_amount
  );
end;
$$;

revoke all on function public.buyer_match_simulation_queue_entry(text, text) from public;
grant execute on function public.buyer_match_simulation_queue_entry(text, text) to authenticated;

create or replace function public.buyer_match_simulation_sale_entries(
  p_order_id text,
  p_queue_ids text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  buyer_order_data jsonb;
  buyer_order_owner_id uuid;
  seller_owner_id uuid;
  seller_sale_key text;
  seller_entry public.simulation_queue%rowtype;
  leg jsonb;
  matched_amount numeric;
  total_matched_amount numeric := 0;
  residual_amount numeric;
  residual_id text;
  residual_data jsonb;
  matched_buyer_order_count integer := 0;
  buyer_order_already_counted boolean := false;
  seller_already_settled boolean := false;
  linked_order_id text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if coalesce(array_length(p_queue_ids, 1), 0) = 0
     or cardinality(p_queue_ids) <> cardinality(array(select distinct unnest(p_queue_ids))) then
    raise exception 'Seller queue entries are required and must be unique';
  end if;

  select order_data, owner_id
  into buyer_order_data, buyer_order_owner_id
  from public.simulation_orders
  where id = p_order_id
  for update;
  if buyer_order_data is null or buyer_order_owner_id <> auth.uid() then
    raise exception 'Buyer order not found';
  end if;
  if coalesce(buyer_order_data ->> 'status', '') not in ('PAIRED', 'PARTIAL', 'PROOF', 'FLAGGED', 'HOLDING') then
    raise exception 'Buyer order is not awaiting seller settlement';
  end if;
  if coalesce((
       select sum(nullif(item ->> 'fill', '')::numeric)
       from jsonb_array_elements(
         case when jsonb_typeof(buyer_order_data -> 'legs') = 'array'
           then buyer_order_data -> 'legs' else '[]'::jsonb end
       ) item
     ), 0) > coalesce(nullif(buyer_order_data ->> 'principal', '')::numeric, 0) + 0.5
     or coalesce((
       select sum(nullif(item ->> 'fill', '')::numeric)
       from jsonb_array_elements(
         case when jsonb_typeof(buyer_order_data -> 'legs') = 'array'
           then buyer_order_data -> 'legs' else '[]'::jsonb end
       ) item
     ), 0) > coalesce(nullif(buyer_order_data ->> 'transferAmt', '')::numeric,
                      nullif(buyer_order_data ->> 'principal', '')::numeric, 0) + 0.5 then
    raise exception 'Buyer order match legs exceed its committed amount';
  end if;

  select owner_id, coalesce(queue_data ->> 'sourceOrderId', id)
  into seller_owner_id, seller_sale_key
  from public.simulation_queue
  where id = p_queue_ids[1];
  if seller_owner_id is null or seller_owner_id = auth.uid() then
    raise exception 'Seller queue entry not found';
  end if;
  perform pg_advisory_xact_lock(hashtext(seller_owner_id::text), hashtext(seller_sale_key));

  perform q.id
  from public.simulation_queue q
  where q.owner_id = seller_owner_id
    and coalesce(q.queue_data ->> 'sourceOrderId', q.id) = seller_sale_key
  order by q.id
  for update;

  select count(distinct coalesce(
           q.queue_data ->> 'matchedBuyerOrderId',
           q.queue_data ->> 'matchedOrderId'
         )),
         coalesce(bool_or(coalesce(
           q.queue_data ->> 'matchedBuyerOrderId',
           q.queue_data ->> 'matchedOrderId'
         ) = p_order_id), false)
  into matched_buyer_order_count, buyer_order_already_counted
  from public.simulation_queue q
  where q.owner_id = seller_owner_id
    and coalesce(q.queue_data ->> 'sourceOrderId', q.id) = seller_sale_key
    and q.queue_data ->> 'status' in ('MATCHED', 'SETTLED')
    and coalesce(q.queue_data ->> 'matchedBuyerOrderId', q.queue_data ->> 'matchedOrderId') is not null;
  if matched_buyer_order_count >= 2 and not buyer_order_already_counted then
    raise exception 'Seller sale is limited to two buyer orders';
  end if;

  if not buyer_order_already_counted and matched_buyer_order_count = 1 then
    if exists (
      select 1
      from public.simulation_queue q
      where q.owner_id = seller_owner_id
        and coalesce(q.queue_data ->> 'sourceOrderId', q.id) = seller_sale_key
        and q.queue_data ->> 'status' = 'WAITING'
        and not (q.id = any(p_queue_ids))
    ) then
      raise exception 'The second buyer order must take the entire remaining seller sale';
    end if;
  end if;

  for leg in
    select item
    from jsonb_array_elements(
      case when jsonb_typeof(buyer_order_data -> 'legs') = 'array'
        then buyer_order_data -> 'legs' else '[]'::jsonb end
    ) item
    where item ->> 'id' = any(p_queue_ids)
  loop
    select *
    into seller_entry
    from public.simulation_queue
    where id = leg ->> 'id'
      and owner_id = seller_owner_id
      and coalesce(queue_data ->> 'sourceOrderId', id) = seller_sale_key;
    if seller_entry.id is null or seller_entry.owner_id = auth.uid() then
      raise exception 'Seller queue entries must belong to one seller sale';
    end if;
    if seller_entry.queue_data ->> 'status' not in ('WAITING', 'MATCHED', 'SETTLED') then
      raise exception 'Seller queue entry is not available';
    end if;
    linked_order_id := coalesce(
      seller_entry.queue_data ->> 'matchedBuyerOrderId',
      seller_entry.queue_data ->> 'matchedOrderId'
    );
    if seller_entry.queue_data ->> 'status' in ('MATCHED', 'SETTLED')
       and linked_order_id is not null
       and linked_order_id <> p_order_id then
      raise exception 'Seller queue entry is already linked to another order';
    end if;
    if seller_entry.queue_data ->> 'maturedSeller' = 'true'
       and seller_entry.queue_data ->> 'saleRequested' is distinct from 'true'
       and not exists (
         select 1
         from public.simulation_orders source_order
         where source_order.id = seller_entry.queue_data ->> 'sourceOrderId'
           and source_order.owner_id = seller_owner_id
           and source_order.order_data ->> 'status' = 'QUEUE'
       ) then
      raise exception 'Seller has not requested a sale';
    end if;
    matched_amount := nullif(leg ->> 'fill', '')::numeric;
    if matched_amount is null then
      raise exception 'Matched amount is required for every seller entry';
    end if;
    if matched_amount <= 0
       or matched_amount > coalesce(nullif(seller_entry.queue_data ->> 'amount', '')::numeric, 0) + 0.5
       or matched_amount > coalesce(nullif(buyer_order_data ->> 'principal', '')::numeric, 0) then
      raise exception 'Invalid seller match amount';
    end if;
    total_matched_amount := total_matched_amount + matched_amount;
    if not buyer_order_already_counted and matched_buyer_order_count = 1
       and seller_entry.queue_data ->> 'status' = 'WAITING'
       and matched_amount + 0.001 < coalesce(nullif(seller_entry.queue_data ->> 'amount', '')::numeric, 0) then
      raise exception 'The second buyer order must take each remaining seller entry in full';
    end if;

    seller_already_settled := seller_entry.queue_data ->> 'status' = 'SETTLED';
    residual_amount := greatest(
      0,
      coalesce(nullif(seller_entry.queue_data ->> 'amount', '')::numeric, 0) - matched_amount
    );
    update public.simulation_queue
    set queue_data = seller_entry.queue_data
          || jsonb_build_object(
               'status', case when seller_already_settled then 'SETTLED' else 'MATCHED' end,
               'amount', matched_amount,
               'matchedAmount', matched_amount,
               'matchedOrderId', p_order_id,
               'matchedBuyerOrderId', p_order_id,
               'matchedBuyerOwnerId', buyer_order_owner_id,
               'matchedBuyerName', coalesce(buyer_order_data ->> 'buyer_name', 'Buyer')
             ),
        updated_at = now()
    where id = seller_entry.id;

    if residual_amount >= 0.01 then
      residual_id := nullif(leg ->> 'residualId', '');
      if residual_id is null then
        residual_id := seller_entry.id || '-R-' || substr(md5(p_order_id), 1, 8);
      end if;
      residual_data := (seller_entry.queue_data
          - 'matchedOrderId' - 'matchedBuyerOrderId' - 'matchedBuyerOwnerId'
          - 'matchedBuyerName' - 'matchedAmount')
        || jsonb_build_object(
             'id', residual_id,
             'sourceOrderId', seller_sale_key,
             'amount', residual_amount,
             'status', 'WAITING'
           );
      insert into public.simulation_queue as existing_queue (id, owner_id, queue_data, updated_at)
      values (residual_id, seller_owner_id, residual_data, now())
      on conflict (id) do update
      set queue_data = excluded.queue_data,
          updated_at = now()
      where existing_queue.owner_id = excluded.owner_id
        and existing_queue.queue_data ->> 'status' = 'WAITING';
      if not found then
        raise exception 'Residual seller queue entry could not be saved';
      end if;
    end if;
  end loop;

  if total_matched_amount > coalesce(nullif(buyer_order_data ->> 'principal', '')::numeric, 0) + 0.5
     or total_matched_amount > coalesce(nullif(buyer_order_data ->> 'transferAmt', '')::numeric,
                                        nullif(buyer_order_data ->> 'principal', '')::numeric, 0) + 0.5 then
    raise exception 'Seller sale allocation exceeds the buyer order amount';
  end if;

  if (select count(*)
      from jsonb_array_elements(
        case when jsonb_typeof(buyer_order_data -> 'legs') = 'array'
          then buyer_order_data -> 'legs' else '[]'::jsonb end
      ) item
      where item ->> 'id' = any(p_queue_ids)) <> cardinality(p_queue_ids) then
    raise exception 'Every seller entry must be part of the buyer order';
  end if;

  return jsonb_build_object(
    'order_id', p_order_id,
    'seller_sale_key', seller_sale_key,
    'queue_ids', to_jsonb(p_queue_ids),
    'status', 'MATCHED'
  );
end;
$$;

revoke all on function public.buyer_match_simulation_sale_entries(text, text[]) from public;
grant execute on function public.buyer_match_simulation_sale_entries(text, text[]) to authenticated;

create or replace function public.buyer_submit_simulation_payment_proof(
  p_order_id text,
  p_proof text,
  p_proof_media text default null,
  p_proof_media_type text default null,
  p_proof_media_name text default null,
  p_proof_media_size bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  buyer_order_data jsonb;
  buyer_order_owner_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select order_data, owner_id
  into buyer_order_data, buyer_order_owner_id
  from public.simulation_orders
  where id = p_order_id
  for update;

  if buyer_order_data is null or buyer_order_owner_id <> auth.uid() then
    raise exception 'Buyer order not found';
  end if;

  if buyer_order_data ->> 'status' = 'PROOF'
     and buyer_order_data ->> 'proof' = p_proof then
    return jsonb_build_object('order_id', p_order_id, 'status', 'PROOF');
  end if;
  if buyer_order_data ->> 'status' <> 'PAIRED' then
    raise exception 'Order is not awaiting payment proof';
  end if;
  if (length(btrim(coalesce(p_proof, ''))) < 4 and p_proof_media is null)
     or length(coalesce(p_proof, '')) > 200 then
    raise exception 'A valid payment reference or attachment is required';
  end if;

  buyer_order_data := jsonb_set(buyer_order_data, '{status}', '"PROOF"'::jsonb, true);
  buyer_order_data := jsonb_set(buyer_order_data, '{proof}', to_jsonb(coalesce(nullif(btrim(p_proof), ''), 'MEDIA-' || floor(random() * 9000 + 1000)::text)), true);
  buyer_order_data := jsonb_set(buyer_order_data, '{proofMedia}', coalesce(to_jsonb(p_proof_media), 'null'::jsonb), true);
  buyer_order_data := jsonb_set(buyer_order_data, '{proofMediaType}', coalesce(to_jsonb(p_proof_media_type), 'null'::jsonb), true);
  buyer_order_data := jsonb_set(buyer_order_data, '{proofMediaName}', coalesce(to_jsonb(p_proof_media_name), 'null'::jsonb), true);
  buyer_order_data := jsonb_set(buyer_order_data, '{proofMediaSize}', coalesce(to_jsonb(p_proof_media_size), 'null'::jsonb), true);

  update public.simulation_orders
  set order_data = buyer_order_data,
      updated_at = now()
  where id = p_order_id;

  return jsonb_build_object('order_id', p_order_id, 'status', 'PROOF');
end;
$$;

revoke all on function public.buyer_submit_simulation_payment_proof(text, text, text, text, text, bigint) from public;
grant execute on function public.buyer_submit_simulation_payment_proof(text, text, text, text, text, bigint) to authenticated;

drop policy if exists "Matched sellers read buyer orders" on public.simulation_orders;
create policy "Matched sellers read buyer orders"
on public.simulation_orders for select
using (
  exists (
    select 1
    from public.simulation_queue q
    where q.owner_id = auth.uid()
      and q.queue_data ->> 'status' in ('MATCHED', 'SETTLED')
      and coalesce(q.queue_data ->> 'matchedBuyerOrderId', q.queue_data ->> 'matchedOrderId') = simulation_orders.id
  )
);

create or replace function public.seller_confirm_simulation_trade(p_order_id text, p_day integer default 0)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  seller_queue_id text;
  buyer_order_data jsonb;
  buyer_order_owner_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select id
  into seller_queue_id
  from public.simulation_queue
  where owner_id = auth.uid()
    and queue_data ->> 'status' = 'MATCHED'
    and coalesce(queue_data ->> 'matchedBuyerOrderId', queue_data ->> 'matchedOrderId') = p_order_id
  for update;

  if seller_queue_id is null then
    raise exception 'No matched seller entry for this order';
  end if;

  select order_data, owner_id
  into buyer_order_data, buyer_order_owner_id
  from public.simulation_orders
  where id = p_order_id
  for update;

  if buyer_order_owner_id = auth.uid() then
    raise exception 'Seller and buyer must be different users';
  end if;

  if buyer_order_data is null or buyer_order_data ->> 'status' not in ('PAIRED', 'PROOF') then
    raise exception 'Order is not awaiting seller payment confirmation';
  end if;

  update public.simulation_orders
  set order_data = jsonb_set(
        jsonb_set(buyer_order_data, '{status}', '"HOLDING"'::jsonb),
        '{unlockedDay}', to_jsonb(coalesce(p_day, 0)), true
      ),
      updated_at = now()
  where id = p_order_id;

  update public.simulation_queue q
  set queue_data = jsonb_set(
        jsonb_set(q.queue_data, '{status}', '"SETTLED"'::jsonb),
        '{settledAt}', to_jsonb(now()), true
      ),
      updated_at = now()
  where coalesce(q.queue_data ->> 'matchedBuyerOrderId', q.queue_data ->> 'matchedOrderId') = p_order_id
    and q.queue_data ->> 'status' = 'MATCHED';

  return jsonb_build_object('order_id', p_order_id, 'status', 'HOLDING');
end;
$$;

revoke all on function public.seller_confirm_simulation_trade(text, integer) from public;
grant execute on function public.seller_confirm_simulation_trade(text, integer) to authenticated;

create or replace function public.preserve_resolved_simulation_status()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  old_status text;
  new_status text;
  linked_buyer_order_id text;
  linked_buyer_order_status text;
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
  elsif tg_table_name = 'simulation_queue' then
    old_status := old.queue_data ->> 'status';
    new_status := new.queue_data ->> 'status';
    linked_buyer_order_id := coalesce(
      old.queue_data ->> 'matchedBuyerOrderId',
      old.queue_data ->> 'matchedOrderId'
    );

    if old_status = 'SETTLED' and new_status in ('MATCHED', 'WAITING') then
      new.queue_data := new.queue_data || old.queue_data
        || jsonb_build_object('status', 'SETTLED');
      if old.queue_data ? 'settledAt' then
        new.queue_data := jsonb_set(new.queue_data, '{settledAt}', old.queue_data -> 'settledAt', true);
      end if;
    elsif old_status = 'MATCHED'
          and linked_buyer_order_id is not null
          and (
            new_status = 'WAITING'
            or coalesce(new.queue_data ->> 'matchedBuyerOrderId',
                        new.queue_data ->> 'matchedOrderId') is distinct from linked_buyer_order_id
          ) then
      select order_data ->> 'status'
      into linked_buyer_order_status
      from public.simulation_orders
      where id = linked_buyer_order_id;

      if linked_buyer_order_status in ('PAIRED', 'PARTIAL', 'PROOF', 'FLAGGED') then
        new.queue_data := new.queue_data || jsonb_build_object(
          'status', 'MATCHED',
          'amount', old.queue_data -> 'amount',
          'matchedAmount', old.queue_data -> 'matchedAmount',
          'matchedOrderId', old.queue_data -> 'matchedOrderId',
          'matchedBuyerOrderId', old.queue_data -> 'matchedBuyerOrderId',
          'matchedBuyerOwnerId', old.queue_data -> 'matchedBuyerOwnerId',
          'matchedBuyerName', old.queue_data -> 'matchedBuyerName'
        );
      elsif linked_buyer_order_status in ('HOLDING', 'TRANSFERRED', 'SETTLED') then
        new.queue_data := new.queue_data || jsonb_build_object(
          'status', 'SETTLED',
          'amount', old.queue_data -> 'amount',
          'matchedAmount', old.queue_data -> 'matchedAmount',
          'matchedOrderId', old.queue_data -> 'matchedOrderId',
          'matchedBuyerOrderId', old.queue_data -> 'matchedBuyerOrderId',
          'matchedBuyerOwnerId', old.queue_data -> 'matchedBuyerOwnerId',
          'matchedBuyerName', old.queue_data -> 'matchedBuyerName'
        );
      end if;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists preserve_resolved_simulation_order_status on public.simulation_orders;
create trigger preserve_resolved_simulation_order_status
before update of order_data on public.simulation_orders
for each row execute function public.preserve_resolved_simulation_status();

drop trigger if exists preserve_resolved_simulation_queue_status on public.simulation_queue;
create trigger preserve_resolved_simulation_queue_status
before update of queue_data on public.simulation_queue
for each row execute function public.preserve_resolved_simulation_status();

create or replace function public.enforce_two_buyer_orders_per_seller_sale()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  seller_sale_key text;
  buyer_order_id text;
  matched_buyer_order_count integer;
  buyer_order_already_counted boolean;
begin
  if new.queue_data ->> 'status' not in ('MATCHED', 'SETTLED') then
    return new;
  end if;

  buyer_order_id := coalesce(
    new.queue_data ->> 'matchedBuyerOrderId',
    new.queue_data ->> 'matchedOrderId'
  );
  if buyer_order_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and old.queue_data ->> 'status' in ('MATCHED', 'SETTLED')
     and coalesce(old.queue_data ->> 'matchedBuyerOrderId', old.queue_data ->> 'matchedOrderId') = buyer_order_id then
    return new;
  end if;

  seller_sale_key := coalesce(new.queue_data ->> 'sourceOrderId', new.id);
  perform pg_advisory_xact_lock(hashtext(new.owner_id::text), hashtext(seller_sale_key));

  select count(distinct coalesce(
           q.queue_data ->> 'matchedBuyerOrderId',
           q.queue_data ->> 'matchedOrderId'
         )),
         coalesce(bool_or(coalesce(
           q.queue_data ->> 'matchedBuyerOrderId',
           q.queue_data ->> 'matchedOrderId'
         ) = buyer_order_id), false)
  into matched_buyer_order_count, buyer_order_already_counted
  from public.simulation_queue q
  where q.owner_id = new.owner_id
    and coalesce(q.queue_data ->> 'sourceOrderId', q.id) = seller_sale_key
    and q.id <> new.id
    and q.queue_data ->> 'status' in ('MATCHED', 'SETTLED')
    and coalesce(q.queue_data ->> 'matchedBuyerOrderId', q.queue_data ->> 'matchedOrderId') is not null;

  if matched_buyer_order_count >= 2 and not buyer_order_already_counted then
    raise exception 'Seller sale is limited to two buyer orders';
  end if;
  return new;
end;
$$;

drop trigger if exists limit_buyers_per_seller_sale on public.simulation_queue;
create trigger limit_buyers_per_seller_sale
before insert or update of queue_data on public.simulation_queue
for each row execute function public.enforce_two_buyer_orders_per_seller_sale();