const { chromium } = require('playwright');
const assert = require('node:assert/strict');

const STORE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const OWNER = '11111111-1111-4111-8111-111111111111';
const clone = value => JSON.parse(JSON.stringify(value));
function fixture() {
  const items = Array.from({ length: 35 }, (_, i) => ({ id: 'item-' + i, model: 'Model ' + i, color: 'Color ' + i, size: '4', price: 2200, quantity: i === 0 ? 2 : 3, photo: 'data:image/jpeg;base64,' + 'A'.repeat(138000) }));
  const orders = Array.from({ length: 20 }, (_, i) => ({ id: 'old-' + i, number: i + 1, itemId: items[i].id, model: items[i].model, color: items[i].color, size: '4', price: 2200, quantity: 1, photo: items[i].photo, customer: 'Existing customer', phone: '', address: '', notes: '', deliveryFee: 0, status: 'تم التوصيل', payment: 'مدفوع', date: '2026-11-01T12:00:00.000Z' }));
  return { version: 1, items, orders };
}
const initial = fixture();
const initialBytes = Buffer.byteLength(JSON.stringify(initial));

(async () => {
  const browser = await chromium.launch({ executablePath: '/usr/bin/chromium', headless: true, args: ['--no-sandbox'] });
  let passed = 0;
  try {
    async function scenario(mode, exercise) {
      const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
      const page = await context.newPage();
      page.setDefaultTimeout(15000);
      const pageErrors = [];
      page.on('pageerror', error => pageErrors.push(error.message));
      const db = { revision: 62, payload: clone(initial) };
      const saleBodies = [];
      let reads = 0, oldWrites = 0, deferred;
      const envelope = () => ({ store_id: STORE, role: 'owner', revision: db.revision, payload: db.payload });
      const reply = (route, data, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(data) });
      function commitSale(body, duplicate = false, revisionGap = false) {
        const item = db.payload.items.find(i => i.id === body.item_id);
        item.quantity -= body.quantity;
        const order = { id: body.request_id, number: 21, itemId: item.id, model: item.model, color: item.color, size: item.size, price: item.price, quantity: body.quantity, deliveryFee: body.delivery_fee, customer: body.customer, phone: body.phone, address: body.address, notes: body.notes, status: body.status, payment: body.payment, photo: item.photo, date: '2026-11-08T12:00:00.000Z', _sale_request: { request_id: body.request_id, item_id: body.item_id } };
        db.payload.orders.push(order);
        db.revision += revisionGap ? 2 : 1;
        return { store_id: STORE, role: 'owner', revision: db.revision, order, new_quantity: item.quantity, duplicate };
      }
      await page.route('https://*.supabase.co/**', async route => {
        const path = new URL(route.request().url()).pathname;
        const body = route.request().postDataJSON();
        if (path === '/auth/v1/token') return reply(route, { access_token: 'test-access-token', refresh_token: 'test-refresh-token', expires_in: 3600, user: { id: OWNER, email: 'owner@example.invalid' } });
        if (path === '/rest/v1/rpc/kenz_get_state') {
          reads++;
          if (mode === 'ack-reload-fail' && reads > 1) return reply(route, { message: 'fixture read unavailable' }, 500);
          return reply(route, envelope());
        }
        if (path === '/rest/v1/kenz_inventory_state') return reply(route, [{ store_id: STORE, revision: db.revision }]);
        if (path === '/rest/v1/rpc/kenz_save_state') {
          oldWrites++;
          assert.equal(body.expected_revision, db.revision);
          db.payload = body.new_payload; db.revision++;
          return reply(route, envelope());
        }
        if (path === '/rest/v1/rpc/kenz_create_sale') {
          saleBodies.push(body);
          assert.ok(Buffer.byteLength(JSON.stringify(body)) < 2000);
          assert.ok(!('new_payload' in body) && !('photo' in body));
          assert.equal(body.expected_store_id, STORE);
          assert.equal(body.expected_revision, 62);
          if (mode === 'network-fail') return route.abort('failed');
          if (mode === 'timeout') return;
          if (mode === 'reject') return reply(route, { code: '22023', message: 'Invalid quantity fixture' }, 400);
          if (mode === 'missing-rpc') return reply(route, { code: 'PGRST202', message: 'Missing atomic RPC fixture' }, 404);
          if (mode === 'conflict') {
            db.revision++; db.payload.items[0].quantity = 0;
            return reply(route, { code: 'PT409', message: 'State changed fixture' }, 409);
          }
          if (mode === 'malformed') { commitSale(body); return reply(route, {}); }
          const result = commitSale(body, mode === 'duplicate' || mode === 'ack-reload-fail', mode === 'revision-gap');
          if (mode === 'deferred' || mode === 'switch-session') { deferred = () => reply(route, result); return; }
          return reply(route, result);
        }
        throw Error('Unexpected request: ' + path);
      });
      if (mode === 'timeout') await page.clock.install();
      await page.goto('http://127.0.0.1:3002/');
      await page.locator('#cloud-login [name=email]').fill('owner@example.invalid');
      await page.locator('#cloud-login [name=password]').fill('local-test-only');
      await page.locator('#cloud-login [type=submit]').click();
      await page.waitForFunction(() => Cloud.ready);
      await page.click('[data-sell="item-0"]');
      await page.locator('#sale-form [name=customer]').fill('عميل فحص');
      await page.locator('#sale-form [name=status]').selectOption('تم التوصيل');
      await page.locator('#sale-form [name=payment]').selectOption('مدفوع');
      const id = await page.locator('#sale-form').getAttribute('data-request-id');
      assert.ok(id);
      await page.locator('#sale-form [type=submit]').click();
      await page.waitForFunction(() => Cloud.writing || document.querySelector('#sale-error').textContent || !document.querySelector('#sale-dialog').open);
      while (!saleBodies.length) await new Promise(resolve => setTimeout(resolve, 5));
      const api = { page, db, saleBodies, get reads() { return reads; }, get oldWrites() { return oldWrites; }, release: () => deferred(), id };
      await exercise(api);
      assert.deepEqual(pageErrors, []);
      console.log('PASS browser: ' + mode);
      passed++;
      await context.close();
    }
    const snapshot = page => page.evaluate(() => ({ revision: Cloud.revision, uncertain: Cloud.uncertain, ready: Cloud.ready, writing: Cloud.writing, orders: state.orders.length, quantity: state.items[0]?.quantity, metadata: state.orders.at(-1)?._sale_request, mainHidden: document.querySelector('main').hidden, message: document.querySelector('#cloud-status').textContent }));
    await scenario('success', async api => {
      await api.page.waitForFunction(() => !Cloud.writing);
      const s = await snapshot(api.page);
      assert.equal(s.orders, 21); assert.equal(s.quantity, 1); assert.equal(s.revision, 63); assert.equal(s.uncertain, false); assert.ok(s.metadata);
      assert.equal(api.reads, 1, 'normal receipt must not redownload full inventory');
      assert.equal(api.saleBodies.length, 1); assert.equal(api.oldWrites, 0);
      await api.page.locator('[data-order]').first().click();
      api.page.once('dialog', d => d.accept());
      await api.page.click('#cancel-order');
      await api.page.waitForFunction(() => state.items[0].quantity === 2);
      assert.equal(api.db.payload.orders.at(-1).status, 'ملغي');
      assert.ok(api.db.payload.orders.at(-1)._sale_request);
    });
    for (const mode of ['duplicate', 'revision-gap']) await scenario(mode, async api => {
      await api.page.waitForFunction(() => !Cloud.writing);
      const s = await snapshot(api.page);
      assert.equal(s.orders, 21); assert.equal(s.quantity, 1); assert.equal(s.uncertain, false); assert.equal(api.reads, 2); assert.equal(api.saleBodies.length, 1);
    });
    await scenario('ack-reload-fail', async api => {
      await api.page.waitForFunction(() => !Cloud.writing);
      const s = await snapshot(api.page);
      assert.equal(s.uncertain, true); assert.match(s.message, /تم تأكيد تسجيل البيع/);
      assert.equal(await api.page.locator('#sale-dialog').isVisible(), false);
      const blocked = await api.page.evaluate(async () => { try { await Cloud.createSale({itemId:'item-0'},'new-id'); return false; } catch { return true; } });
      assert.equal(blocked, true); assert.equal(api.saleBodies.length, 1);
    });
    for (const mode of ['network-fail', 'malformed']) await scenario(mode, async api => {
      await api.page.waitForFunction(() => !Cloud.writing);
      const s = await snapshot(api.page);
      assert.equal(s.uncertain, true); assert.equal(s.orders, 20); assert.equal(s.quantity, 2);
      await api.page.locator('#sale-form [type=submit]').click();
      await api.page.waitForFunction(() => document.querySelector('#sale-error').textContent.includes('حدّث البيانات'));
      assert.equal(api.saleBodies.length, 1, 'unknown result must block automatic/repeated sale');
    });
    await scenario('timeout', async api => {
      await api.page.clock.fastForward(31000);
      await api.page.waitForFunction(() => !Cloud.writing);
      const s = await snapshot(api.page);
      assert.equal(s.uncertain, true); assert.equal(s.orders, 20); assert.match(await api.page.locator('#sale-error').textContent(), /مهلة الاتصال/);
    });
    for (const mode of ['reject', 'missing-rpc']) await scenario(mode, async api => {
      await api.page.waitForFunction(() => !Cloud.writing);
      const s = await snapshot(api.page);
      assert.equal(s.uncertain, false); assert.equal(s.orders, 20); assert.equal(s.quantity, 2);
      const message = await api.page.locator('#sale-error').textContent();
      assert.match(message, mode === 'reject' ? /HTTP 400.*22023.*Invalid quantity fixture/ : /HTTP 404.*PGRST202.*Missing atomic RPC fixture/);
    });
    await scenario('conflict', async api => {
      await api.page.waitForFunction(() => !Cloud.writing);
      const s = await snapshot(api.page);
      assert.equal(s.quantity, 0); assert.equal(s.orders, 20); assert.equal(api.saleBodies.length, 1); assert.equal(api.reads, 2);
    });
    await scenario('deferred', async api => {
      await api.page.locator('#sale-form').evaluate(form => form.requestSubmit());
      assert.equal(api.saleBodies.length, 1);
      await api.release();
      await api.page.waitForFunction(() => !Cloud.writing);
      const s = await snapshot(api.page); assert.equal(s.quantity, 1); assert.equal(s.orders, 21);
    });
    await scenario('switch-session', async api => {
      await api.page.evaluate(() => Cloud.signOutLocal());
      await api.release();
      await api.page.waitForFunction(() => Cloud.session === null);
      const s = await snapshot(api.page); assert.equal(s.orders, 0); assert.equal(s.mainHidden, true);
    });
    console.log(JSON.stringify({ browserScenarios: passed, fixtureBytes: initialBytes, externalRequests: 0 }));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
