-- Existing organization installations only. Run this file on its own.
-- Preserve counters, business records, policies, and other RPCs.
begin;

create or replace function public.inventory_next_no(p_prefix text)
returns text language plpgsql security definer set search_path = public as $$
declare
  next_value integer;
  today date := current_date;
  oid uuid := public.inventory_current_organization_id();
begin
  if auth.uid() is null or oid is null then
    raise exception 'Organization is required';
  end if;
  insert into public.inventory_document_counters(user_id, organization_id, document_date, prefix, last_number)
  values(auth.uid(), oid, today, p_prefix, 1)
  on conflict(organization_id, document_date, prefix)
  do update set last_number = public.inventory_document_counters.last_number + 1
  returning last_number into next_value;
  return p_prefix || to_char(today, 'YYYYMMDD') || lpad(next_value::text, 4, '0');
end $$;

revoke all on function public.inventory_next_no(text) from public, anon;
grant execute on function public.inventory_next_no(text) to authenticated;
notify pgrst, 'reload schema';
commit;
