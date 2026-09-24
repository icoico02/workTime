# Cost Access and Profit Warnings

Apply `inventory_profit_controls.sql` last, after all existing inventory scripts
including `inventory_batches.sql`. Run the entire file in one SQL Editor request.
It is transactional and can be rerun. The updated frontend requires this migration;
it does not fall back to the old unrestricted reads if the new RPC is missing.

The overview's business controls are available only to the organization's
`super_admin`. Amount and percentage warnings are independently enabled. Defaults
are 10 currency units per item and 15 percent. A value exactly equal to its threshold
does not trigger a warning; either enabled threshold can trigger one.

Order amount warnings compare total gross profit divided by total item quantity.
Margin is gross profit divided by revenue. With zero revenue, margin is displayed
as not applicable; a loss still triggers an enabled margin warning. Product and
checkout calculations use reference cost and are labelled estimates. Fulfilled
orders use their recorded actual costs. Rules only change presentation, never
historical business amounts. Current-page changes apply immediately; other open
pages refresh rules on focus and every 30 seconds.

Cost-bearing base tables have a restrictive super-admin RLS guard. The
`inventory_read` RPC authenticates the caller, scopes rows to the current shop and
order visibility, and projects an explicit public field whitelist for other roles.
This includes omitting cost-derived purchase movement amounts. Batch, supplier
price, allocation, audit and settings tables retain their organization policies
and also receive the restrictive guard. Privileged write errors omit PostgreSQL
DETAIL, which can otherwise contain complete rows. Ordinary product edits preserve
the existing cost. Purchase cost registration requires a super administrator.

Do not expose a service-role key in a browser. Do not run older migrations after
this migration without reapplying this file: they can replace write function guards.

## Local Verification

`node tests/inventory-profit.test.mjs` verifies threshold boundaries and toggles.

`node tests/inventory-profit-security.mjs /path/to/pglite/dist/index.js` applies
the actual migrations in an isolated PostgreSQL-compatible PGlite database and
checks repeated migration execution, role isolation, cross-shop reads, cost-free
responses, settings authorization, cost-preserving product edits, and error detail
redaction. The fixture supplies the salesperson column early to accommodate a
circular dependency in the older organization/order scripts.

These tests do not execute against the hosted Supabase database. After deployment,
verify using separate super-admin and ordinary-member accounts.
