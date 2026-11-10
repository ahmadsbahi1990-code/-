# KENZ BUTIK DEPOSU

Static Arabic inventory app, served by GitHub Pages with Supabase authentication
and store membership. `index.html` loads the local `photos.js` helper.

## Private photo storage

Deployment order for the existing live v1 store:

1. Run **only** `supabase/migrations/20261110_private_photos.sql` in Supabase's
   SQL Editor in **Database** mode. It requires the existing shared-store schema
   and the atomic sale migration below. Installation creates the private bucket,
   policies, archive table and RPCs; it does not convert or replace inventory.
2. After the SQL succeeds, deploy `index.html` and `photos.js` together.
3. Sign in as the store owner and press **تفعيل تخزين الصور**. Keep the page
   open until completion. Then refresh other devices to load the new frontend.

The app uploads each distinct original image as immutable bytes into the private
`kenz-model-photos` bucket. Its object name is `<store UUID>/<SHA-256>.<extension>`;
only current members can insert/read their store's images. Authenticated clients
cannot overwrite, delete, move, or make this bucket public, even if other buckets
use broad permissive policies. Images are fetched with the user's token and
displayed through temporary blob URLs; no token is written to the DOM.

After all uploads, an owner-only RPC locks the inventory, checks its revision,
archives the exact v1 payload, and replaces only version/photo fields. A missing
object or revision conflict rolls back the metadata change. Interrupted uploads
are safe to reconcile using the immutable hash; uncertain metadata writes require
a refresh. Old clients cannot downgrade v2 or bypass owner migration via the
legacy save endpoint. The atomic sale RPC works with both versions.

Historical orders retain their photo reference when a model's picture changes.
There is no automatic image deletion: old orders and backups may still need an
image. Unreferenced uploads from cancelled/conflicting edits can remain as well.
The one-time v1 archive is kept in the database for recovery and still counts
toward database usage. The owner-only `kenz_get_photo_migration_backup` RPC can
retrieve it. No automatic rollback replaces newer business records.

The metadata document remains limited to 10 MiB. Each stored image is limited to
1 MiB; the existing picker compresses new photos to the legacy 400,000-character
limit. Images consume the project's Storage quota separately. This removes photo
duplication from sales; it does not make project storage unlimited.

Backups exported after migration use portable JSON:
`{format:"kenz-backup", version:2, payload, images:{[reference]:dataURI}}`.
Each image appears once. Restore verifies all hashes/types before uploading,
remaps references to the current store, then uses the metadata revision check.
Legacy v1 backups can also be restored after migration. Backup files are capped
at 100 MiB; do not discard a good backup until its replacement is verified.

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
That repair addresses sale transport. The separate photo migration above removes
the repeated embedded images from the document.

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

Run photo client and app integration tests, and repeat the sale tests with v2:

```sh
node tests/photo-client-browser.cjs
node tests/photo-app-browser.cjs
KENZ_PAYLOAD_VERSION=2 node tests/atomic-sale-browser.cjs
```

The private photo SQL tests use an additional local-only Storage fixture, not
real Supabase/S3 objects. They exercise RLS with broad pre-existing policies,
owner/staff isolation, immutable objects, migration rollback/replay, archived
historical pictures, legacy upgrade/downgrade rejection and atomic v2 sales.

After the original fixture and atomic migration above, in that same local test
container (replace its name if different):

```sh
docker exec -i kenz-sale-tests psql -X -v ON_ERROR_STOP=1 -U postgres < tests/fixtures/storage_schema.sql
docker exec -i kenz-sale-tests psql -X -v ON_ERROR_STOP=1 -U postgres < supabase/migrations/20261110_private_photos.sql
docker exec -i kenz-sale-tests psql -X -v ON_ERROR_STOP=1 -U postgres < supabase/migrations/20261110_private_photos.sql
docker exec -i kenz-sale-tests psql -X -v ON_ERROR_STOP=1 -U postgres < tests/sql/private_photos.sql
docker exec -i kenz-sale-tests psql -X -v ON_ERROR_STOP=1 -U postgres < tests/sql/atomic_sale.sql
```

The photo SQL fixture includes a representative 7.6 MB migration with 55 photo
references: it retains 35 unique image objects and returns about 16 KB of metadata.
Browser coverage includes lost migration acknowledgements, changed membership,
photo edits, atomic sales, portable backups and failed upload/import rollback.
