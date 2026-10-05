alter table public.profiles
  add column if not exists referral_code text,
  add column if not exists referred_by uuid;

update public.profiles
set referral_code = 'M' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))
where referral_code is null;

alter table public.profiles
  alter column referral_code set default 'M' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12)),
  alter column referral_code set not null;

create unique index if not exists profiles_referral_code_uidx
  on public.profiles (referral_code);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'profiles_referred_by_fkey'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_referred_by_fkey
      foreign key (referred_by) references public.profiles(id) on delete set null;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'profiles_not_self_referred_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_not_self_referred_check
      check (referred_by is null or referred_by <> id);
  end if;
end;
$$;

create index if not exists profiles_referred_by_idx
  on public.profiles (referred_by);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  invite_code text;
  inviter_id uuid;
begin
  invite_code := nullif(upper(btrim(new.raw_user_meta_data ->> 'referral_code')), '');

  if invite_code is not null then
    select id into inviter_id
    from public.profiles
    where referral_code = invite_code;

    if inviter_id is null then
      raise exception 'Invalid referral code';
    end if;
  end if;

  insert into public.profiles (id, display_name, referred_by)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'display_name', 'New user'),
    inviter_id
  );

  insert into public.profile_contacts (user_id, phone)
  values (
    new.id,
    nullif(btrim(new.raw_user_meta_data ->> 'phone'), '')
  );

  return new;
end;
$$;

create or replace function public.get_my_referrals()
returns table (
  user_id uuid,
  parent_id uuid,
  display_name text,
  created_at timestamptz,
  level integer
)
language sql
stable
security definer
set search_path = public
as $$
  with recursive referral_tree as (
    select
      p.id as user_id,
      p.referred_by as parent_id,
      p.display_name,
      p.created_at,
      1 as level,
      array[p.id] as visited
    from public.profiles p
    where p.referred_by = auth.uid()
      and auth.uid() is not null

    union all

    select
      child.id,
      child.referred_by,
      child.display_name,
      child.created_at,
      parent.level + 1,
      parent.visited || child.id
    from public.profiles child
    join referral_tree parent on child.referred_by = parent.user_id
    where parent.level < 3
      and not child.id = any(parent.visited)
  )
  select tree.user_id, tree.parent_id, tree.display_name, tree.created_at, tree.level
  from referral_tree tree
  order by tree.level, tree.created_at;
$$;

revoke all on function public.get_my_referrals() from public, anon;
grant execute on function public.get_my_referrals() to authenticated;
