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

drop trigger if exists zz_enforce_one_active_bid_per_user on public.simulation_orders;
create trigger zz_enforce_one_active_bid_per_user
before insert or update on public.simulation_orders
for each row execute function public.enforce_one_active_bid_per_user();
