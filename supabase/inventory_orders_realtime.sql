-- Enable realtime updates for pending sales-order reminders.
-- Safe to run more than once.

do $$
begin
  begin
    alter publication supabase_realtime add table public.inventory_orders;
  exception
    when duplicate_object then null;
    when undefined_object then
      raise notice 'supabase_realtime publication not found; enable Realtime for inventory_orders in the dashboard if needed';
  end;
end $$;

notify pgrst, 'reload schema';
