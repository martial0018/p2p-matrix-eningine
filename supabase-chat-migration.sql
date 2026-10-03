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

drop policy if exists "Admins insert simulation control" on public.simulation_control;
create policy "Admins insert simulation control"
on public.simulation_control for insert
with check (public.is_admin());

insert into public.simulation_control (id)
values (true)
on conflict (id) do nothing;

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