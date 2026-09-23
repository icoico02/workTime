create or replace function public.check_approval_status(p_username text)
returns table (
  approval_status text,
  rejection_reason text
)
language sql
security definer
set search_path = public
stable
as $$
  select
    p.approval_status::text,
    case
      when to_jsonb(p) ? 'rejection_reason'
        then to_jsonb(p) ->> 'rejection_reason'
      else null
    end as rejection_reason
  from public.profiles as p
  where lower(trim(p.username)) = lower(trim(p_username))
  limit 1;
$$;

grant execute on function public.check_approval_status(text) to anon, authenticated;
