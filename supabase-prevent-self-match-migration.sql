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

drop trigger if exists zz_prevent_buyer_matching_own_seller_offer on public.simulation_orders;
create trigger zz_prevent_buyer_matching_own_seller_offer
before insert or update on public.simulation_orders
for each row execute function public.prevent_buyer_matching_own_seller_offer();
