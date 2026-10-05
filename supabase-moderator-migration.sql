alter table public.profiles
  add column if not exists moderator_previous_role public.app_role,
  add column if not exists arbiter_previous_role public.app_role;

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
