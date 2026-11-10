const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { readFile } = require('node:fs/promises');

const STORE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const OWNER = '11111111-1111-4111-8111-111111111111';
const OTHER_STORE = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const clone = value => JSON.parse(JSON.stringify(value));
const BASE = process.env.KENZ_TEST_URL || 'http://127.0.0.1:3002/';
const prefix = '/storage/v1/object/';
const bucket = 'kenz-model-photos/';
const fromInline = value => {
  const match = /^data:image\/(jpeg|png|webp);base64,(.+)$/.exec(value);
  assert.ok(match, 'fixture must contain a supported inline image');
  const bytes = Buffer.from(match[2], 'base64');
  const ext = match[1] === 'jpeg' ? 'jpg' : match[1];
  return { bytes, mime: 'image/' + match[1], ref: STORE + '/' + createHash('sha256').update(bytes).digest('hex') + '.' + ext };
};

(async () => {
  const browser = await chromium.launch({ executablePath: '/usr/bin/chromium', headless: true, args: ['--no-sandbox'] });
  let passed = 0;
  try {
    const generator = await browser.newPage();
    const pictures = await generator.evaluate(() => ['#ff0000', '#0000ff'].map(color => {
      const canvas = document.createElement('canvas'); canvas.width = canvas.height = 2;
      const ctx = canvas.getContext('2d'); ctx.fillStyle = color; ctx.fillRect(0, 0, 2, 2);
      return canvas.toDataURL('image/png');
    }));
    await generator.close();
    const oldAsset = fromInline(pictures[0]), historicalAsset = fromInline(pictures[1]);
    function fixture(version = 1) {
      const item = { id: 'item-0', model: 'موديل فحص', color: 'أحمر', size: '4', price: 2200, quantity: 3, photo: version === 1 ? pictures[0] : oldAsset.ref };
      const order = (id, number, picture) => ({ id, number, itemId: item.id, model: item.model, color: item.color, size: item.size, price: item.price, quantity: 1, photo: picture, customer: 'عميل قديم', phone: '', address: '', notes: '', deliveryFee: 0, status: 'تم التوصيل', payment: 'مدفوع', date: '2026-11-01T12:00:00.000Z', _sale_request: { retained: 'historical request metadata' } });
      return { version, items: [item], orders: [order('old-0', 1, item.photo), order('old-1', 2, version === 1 ? pictures[1] : historicalAsset.ref)], custom: { preserve: true } };
    }
    async function scenario(name, config, exercise) {
      const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, acceptDownloads: true });
      const page = await context.newPage(); page.setDefaultTimeout(15000);
      const pageErrors = []; page.on('pageerror', error => pageErrors.push(error.message));
      const db = { storeId: STORE, revision: 62, payload: fixture(config.version || 1), archive: null };
      const initial = clone(db.payload), objects = new Map(), events = [], unexpected = [];
      if (db.payload.version === 2) for (const asset of [oldAsset, historicalAsset]) objects.set(asset.ref, asset);
      let releaseUpload, migrationCalls = 0, saveCalls = 0, saleCalls = 0;
      const envelope = () => ({ store_id: db.storeId, role: config.role || 'owner', revision: db.revision, payload: db.payload });
      const reply = (route, data, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(data) });
      await page.route('https://*.supabase.co/**', async route => {
        const req = route.request(), path = decodeURIComponent(new URL(req.url()).pathname);
        events.push({ path, method: req.method() });
        assert.equal(req.headers().apikey.startsWith('sb_publishable_'), true);
        if (path.startsWith(prefix)) {
          assert.equal(req.headers().authorization, 'Bearer test-access-token');
          if (path.startsWith(prefix + 'authenticated/' + bucket)) {
            const ref = path.slice((prefix + 'authenticated/' + bucket).length), asset = objects.get(ref);
            if (!asset) return reply(route, { message: 'Object not found', error: 'not_found' }, 404);
            return route.fulfill({ status: 200, contentType: asset.mime, body: asset.bytes });
          }
          if (path.startsWith(prefix + bucket) && req.method() === 'POST') {
            const ref = path.slice((prefix + bucket).length), bytes = req.postDataBuffer();
            assert.equal(req.headers()['x-upsert'], 'false');
            assert.equal(ref.split('/')[0], STORE);
            assert.equal(ref.split('/')[1].split('.')[0], createHash('sha256').update(bytes).digest('hex'));
            if (config.failUpload) return reply(route, { message: 'fixture upload failed' }, 500);
            if (objects.has(ref)) return reply(route, { statusCode: '409', error: 'Duplicate', message: 'The resource already exists' }, 409);
            const asset = { ref, bytes, mime: req.headers()['content-type'] };
            objects.set(ref, asset);
            if (config.deferUpload) { releaseUpload = () => reply(route, { Key: bucket + ref }); return; }
            return reply(route, { Key: bucket + ref });
          }
        }
        const body = req.postData() ? req.postDataJSON() : undefined;
        if (path === '/auth/v1/token') return reply(route, { access_token: 'test-access-token', refresh_token: 'test-refresh-token', expires_in: 3600, user: { id: OWNER, email: 'owner@example.invalid' } });
        if (path === '/rest/v1/rpc/kenz_get_state_v2') return reply(route, envelope());
        if (path === '/rest/v1/kenz_inventory_state') return reply(route, [{ store_id: db.storeId, revision: db.revision }]);
        if (path === '/rest/v1/rpc/kenz_migrate_photos') {
          migrationCalls++;
          assert.deepEqual(Object.keys(body).sort(), ['expected_revision', 'expected_store_id']);
          assert.equal(body.expected_store_id, STORE); assert.equal(body.expected_revision, 62);
          if (config.conflict || config.switchStoreOnConflict) { db.revision++; if (config.switchStoreOnConflict) db.storeId = OTHER_STORE; return reply(route, { code: 'PT409', message: 'تغيّرت البيانات من جهاز آخر.' }, 409); }
          assert.equal(db.payload.version, 1); db.archive = clone(db.payload);
          let count = 0;
          for (const record of [...db.payload.items, ...db.payload.orders]) if (record.photo) {
            const asset = fromInline(record.photo); assert.ok(objects.has(asset.ref), 'migration requires every uploaded object');
            assert.deepEqual(objects.get(asset.ref).bytes, asset.bytes, 'legacy image bytes must not be recompressed');
            record.photo = asset.ref; count++;
          }
          db.payload.version = 2; db.revision++;
          if (config.loseMigrationAck) return route.abort('failed');
          return reply(route, { ...envelope(), duplicate: false, migration: { unique_images: objects.size, photo_references: count, before_bytes: Buffer.byteLength(JSON.stringify(initial)), after_bytes: Buffer.byteLength(JSON.stringify(db.payload)) } });
        }
        if (path === '/rest/v1/rpc/kenz_save_state_v2') {
          saveCalls++;
          assert.equal(body.expected_store_id, STORE); assert.equal(body.expected_revision, db.revision);
          assert.equal(body.new_payload.version, 2);
          for (const record of [...body.new_payload.items, ...body.new_payload.orders]) if (record.photo) {
            assert.ok(!record.photo.startsWith('data:')); assert.ok(objects.has(record.photo), 'image upload must finish before metadata commit');
          }
          db.payload = clone(body.new_payload); db.revision++; return reply(route, envelope());
        }
        if (path === '/rest/v1/rpc/kenz_create_sale') {
          saleCalls++;
          assert.ok(Buffer.byteLength(JSON.stringify(body)) < 2000); assert.equal('photo' in body, false); assert.equal('new_payload' in body, false);
          const item = db.payload.items[0]; item.quantity -= body.quantity;
          const order = { ...db.payload.orders[0], id: body.request_id, number: 3, photo: item.photo, customer: body.customer, status: body.status, payment: body.payment, date: '2026-11-10T12:00:00.000Z' };
          db.payload.orders.push(order); db.revision++;
          return reply(route, { store_id: STORE, role: 'owner', revision: db.revision, order, new_quantity: item.quantity, duplicate: false });
        }
        unexpected.push(path); return reply(route, { message: 'Unexpected test request ' + path }, 500);
      });
      await page.goto(BASE);
      await page.locator('#cloud-login [name=email]').fill('owner@example.invalid');
      await page.locator('#cloud-login [name=password]').fill('local-test-only');
      await page.locator('#cloud-login [type=submit]').click(); await page.waitForFunction(() => Cloud.ready);
      await exercise({ page, db, initial, objects, events, get migrationCalls() { return migrationCalls; }, get saveCalls() { return saveCalls; }, get saleCalls() { return saleCalls; }, release: () => releaseUpload() });
      assert.deepEqual(unexpected, []); assert.deepEqual(pageErrors, []);
      console.log('PASS photo app: ' + name); passed++; await context.close();
    }

    await scenario('legacy migration deduplicates current and historical photos', {}, async api => {
      await api.page.click('#cloud-photo-migrate');
      await api.page.waitForFunction(() => !Cloud.writing && state.version === 2);
      assert.equal(api.migrationCalls, 1); assert.equal(api.objects.size, 2);
      assert.equal(api.events.filter(e => e.method === 'POST' && e.path.startsWith(prefix + bucket)).length, 2);
      assert.deepEqual(api.db.archive, api.initial);
      const expected = clone(api.initial); expected.version = 2;
      for (const row of [...expected.items, ...expected.orders]) row.photo = fromInline(row.photo).ref;
      assert.deepEqual(api.db.payload, expected);
      await api.page.waitForFunction(() => document.querySelector('#inventory-body img')?.src.startsWith('blob:'));
      assert.equal(await api.page.locator('img[src*="test-access-token"]').count(), 0);
      assert.equal(await api.page.locator('#cloud-photo-panel').isVisible(), false);
    });
    await scenario('failed image upload leaves all business metadata untouched', { failUpload: true }, async api => {
      await api.page.click('#cloud-photo-migrate'); await api.page.waitForFunction(() => !Cloud.writing);
      assert.equal(api.migrationCalls, 0); assert.deepEqual(api.db.payload, api.initial); assert.equal(api.db.revision, 62);
      assert.equal(await api.page.evaluate(() => Cloud.uncertain), false);
    });
    await scenario('migration revision conflict never overwrites newer inventory', { conflict: true }, async api => {
      await api.page.click('#cloud-photo-migrate'); await api.page.waitForFunction(() => !Cloud.writing);
      assert.equal(api.migrationCalls, 1); assert.deepEqual(api.db.payload, api.initial); assert.equal(api.db.revision, 63);
      assert.equal(await api.page.evaluate(() => state.version), 1);
    });
    await scenario('lost migration acknowledgement blocks writes until sync confirms conversion', { loseMigrationAck: true }, async api => {
      await api.page.click('#cloud-photo-migrate');
      await api.page.waitForFunction(() => !Cloud.writing && Cloud.uncertain);
      assert.equal(api.db.payload.version, 2); assert.equal(api.db.revision, 63);
      assert.equal(await api.page.evaluate(() => state.version), 1);
      assert.equal(api.migrationCalls, 1); assert.deepEqual(api.db.archive, api.initial);
      assert.equal(await api.page.locator('#cloud-photo-migrate').isDisabled(), true);
      const blocked = await api.page.evaluate(async () => {
        let migrationBlocked = false, saleBlocked = false;
        try { await Cloud.migratePhotos(); } catch { migrationBlocked = true; }
        try { await Cloud.createSale({ itemId: 'item-0' }, 'must-not-submit'); } catch { saleBlocked = true; }
        return migrationBlocked && saleBlocked;
      });
      assert.equal(blocked, true); assert.equal(api.migrationCalls, 1); assert.equal(api.saleCalls, 0);
      await api.page.click('#cloud-sync');
      await api.page.waitForFunction(() => !Cloud.loading && !Cloud.uncertain && state.version === 2);
      await api.page.evaluate(() => Cloud.migratePhotos());
      assert.equal(api.migrationCalls, 1, 'confirmed conversion must not submit a second migration');
      assert.equal(api.objects.size, 2);
      assert.equal(await api.page.locator('#cloud-photo-panel').isVisible(), false);
    });
    await scenario('store reassignment on conflict clears migration busy state in the same login', { switchStoreOnConflict: true }, async api => {
      const epoch = await api.page.evaluate(() => Cloud.epoch);
      await api.page.click('#cloud-photo-migrate');
      await api.page.waitForFunction(store => !Cloud.writing && !Cloud.loading && Cloud.storeId === store, OTHER_STORE);
      assert.equal(await api.page.evaluate(() => Cloud.epoch), epoch);
      assert.equal(await api.page.evaluate(() => Cloud.uncertain), false);
      assert.equal(await api.page.locator('#cloud-photo-migrate').isEnabled(), true);
      assert.equal(await api.page.locator('#cloud-sync').isEnabled(), true);
      assert.equal(api.migrationCalls, 1); assert.deepEqual(api.db.payload, api.initial);
    });
    await scenario('staff cannot initiate the owner migration', { role: 'staff' }, async api => {
      assert.equal(await api.page.locator('#cloud-photo-migrate').isVisible(), false);
      assert.equal(api.migrationCalls, 0);
    });
    await scenario('v2 photo edit uploads before save and preserves historical photos', { version: 2 }, async api => {
      await api.page.click('[data-edit="item-0"]');
      await api.page.locator('#item-photo').setInputFiles({ name: 'replacement.png', mimeType: 'image/png', buffer: historicalAsset.bytes });
      await api.page.waitForFunction(() => !document.querySelector('#item-form [type=submit]').disabled);
      await api.page.locator('#item-form [type=submit]').click();
      await api.page.waitForFunction(() => !Cloud.writing && !document.querySelector('#item-dialog').open);
      assert.equal(api.saveCalls, 1); assert.notEqual(api.db.payload.items[0].photo, oldAsset.ref);
      assert.deepEqual(api.db.payload.orders, api.initial.orders);
      const uploadAt = api.events.findIndex(e => e.method === 'POST' && e.path.startsWith(prefix + bucket));
      const commitAt = api.events.findIndex(e => e.path === '/rest/v1/rpc/kenz_save_state_v2');
      assert.ok(uploadAt >= 0 && commitAt > uploadAt);
      await api.page.click('[data-sell="item-0"]');
      await api.page.locator('#sale-form [name=customer]').fill('عميل فحص');
      await api.page.locator('#sale-form [type=submit]').click(); await api.page.waitForFunction(() => !Cloud.writing);
      assert.equal(api.saleCalls, 1); assert.equal(api.db.payload.orders.at(-1).photo, api.db.payload.items[0].photo);
      assert.equal(api.db.payload.orders[0].photo, oldAsset.ref);
    });
    await scenario('portable export includes each private image once', { version: 2 }, async api => {
      const downloadPromise = api.page.waitForEvent('download'); await api.page.click('#export');
      const download = await downloadPromise; const archive = JSON.parse(await readFile(await download.path(), 'utf8'));
      assert.equal(archive.format, 'kenz-backup'); assert.equal(archive.version, 2); assert.deepEqual(archive.payload, api.db.payload);
      assert.deepEqual(Object.keys(archive.images).sort(), [oldAsset.ref, historicalAsset.ref].sort());
      assert.equal(archive.images[oldAsset.ref], pictures[0]); assert.equal(archive.images[historicalAsset.ref], pictures[1]);
      assert.equal(api.saveCalls, 0);
    });
    await scenario('portable restore from another store remaps references and preserves metadata', { version: 2 }, async api => {
      const foreignStore = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      const restored = clone(api.initial), images = {};
      for (const record of [...restored.items, ...restored.orders]) {
        const currentRef = record.photo;
        record.photo = currentRef.replace(STORE, foreignStore);
        images[record.photo] = currentRef === oldAsset.ref ? pictures[0] : pictures[1];
      }
      restored.items[0].quantity = 8;
      const archive = { format: 'kenz-backup', version: 2, payload: restored, images };
      api.page.once('dialog', dialog => dialog.accept());
      await api.page.locator('#import-file').setInputFiles({ name: 'portable.json', mimeType: 'application/json', buffer: Buffer.from(JSON.stringify(archive)) });
      await api.page.waitForFunction(() => !Cloud.writing && state.items[0].quantity === 8);
      assert.equal(api.saveCalls, 1);
      const expected = clone(api.initial); expected.items[0].quantity = 8;
      assert.deepEqual(api.db.payload, expected);
    });
    await scenario('incomplete portable restore never commits metadata', { version: 2 }, async api => {
      const archive = { format: 'kenz-backup', version: 2, payload: clone(api.initial), images: { [oldAsset.ref]: pictures[0] } };
      archive.payload.items[0].quantity = 8;
      api.page.once('dialog', dialog => dialog.accept());
      await api.page.locator('#import-file').setInputFiles({ name: 'missing-image.json', mimeType: 'application/json', buffer: Buffer.from(JSON.stringify(archive)) });
      await api.page.waitForFunction(() => document.querySelector('#message').textContent.includes('لم يتم الاستيراد'));
      assert.equal(api.saveCalls, 0); assert.deepEqual(api.db.payload, api.initial);
      assert.equal(api.events.filter(e => e.method === 'POST' && e.path.startsWith(prefix + bucket)).length, 0);
    });
    await scenario('account switch during upload cannot commit metadata or restore private display', { deferUpload: true }, async api => {
      await api.page.click('#cloud-photo-migrate');
      await api.page.waitForFunction(() => Cloud.writing);
      while (!api.events.some(e => e.method === 'POST' && e.path.startsWith(prefix + bucket))) await new Promise(resolve => setTimeout(resolve, 5));
      await api.page.evaluate(() => Cloud.signOutLocal()); await api.release();
      await api.page.waitForTimeout(100);
      assert.equal(api.migrationCalls, 0); assert.deepEqual(api.db.payload, api.initial);
      assert.equal(await api.page.locator('main').isVisible(), false);
      assert.equal(await api.page.locator('img[src^="blob:"]').count(), 0);
    });
    console.log(JSON.stringify({ photoAppScenarios: passed, externalRequests: 0 }));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
