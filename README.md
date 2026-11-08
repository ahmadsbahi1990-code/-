# KENZ BUTIK DEPOSU

Static Arabic inventory app, served by GitHub Pages with Supabase authentication
and store membership. `index.html` is self-contained.

## Atomic sale repair

The old sale handler uploaded and downloaded the complete inventory document,
including every photo. The new handler sends only sale fields to
`kenz_create_sale` and applies the returned receipt. It retains a request ID for
each sale form, checks store/revision, and never retries an unknown outcome
automatically. Definite server rejections now include their error code/message.

Deployment order:

1. Run `supabase/migrations/20261108_atomic_sale.sql` in the existing project's
   SQL Editor, using **Database** mode. This migration creates one RPC and its
   permissions. It does not seed, replace, or clear business records.
2. Deploy the changed `index.html` only after that migration succeeds.
3. Confirm one real sale and its quantity on another device. Check the orders
   list before re-entering a sale whose previous outcome was unclear.

Existing full-document editing/import RPCs and the 10 MiB document limit remain.
This patch addresses the sale transport; it does not migrate photo storage.

## Validation

The SQL fixture is local-only: its `auth.users` and `auth.uid()` stand in for
Supabase. Never execute the fixture or test scripts in the live project.

With PostgreSQL 17 running locally (the test container is `kenz-sale-tests`):

```sh
docker exec -i kenz-sale-tests psql -X -v ON_ERROR_STOP=1 -U postgres < tests/fixtures/live_schema.sql
docker exec -i kenz-sale-tests psql -X -v ON_ERROR_STOP=1 -U postgres < supabase/migrations/20261108_atomic_sale.sql
docker exec -i kenz-sale-tests psql -X -v ON_ERROR_STOP=1 -U postgres < tests/sql/atomic_sale.sql
```

The SQL tests cover owner/staff access, no overselling, request replay,
cancellation replay, revision conflicts, direct-write denial and size-limit
rollback. Race fixtures also exercise two concurrent sales, simultaneous retries
and membership removal while a sale is in progress.

To run the browser suite, serve this checkout on `127.0.0.1:3002`, with Node,
Playwright and Chromium installed:

```sh
python3 -m http.server 3002 --bind 127.0.0.1
node tests/atomic-sale-browser.cjs
```

All Supabase browser requests are intercepted. The browser suite uses a synthetic
7.6 MB inventory and tests successful/duplicate sales, slow or failed network,
server rejection, revision conflicts, cancellation and account switching.
It never signs in to or mutates the live store.
