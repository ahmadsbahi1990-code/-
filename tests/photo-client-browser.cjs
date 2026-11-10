const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const crypto=require('node:crypto');
const STORE='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',OTHER='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const PNG='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1VQAAAAASUVORK5CYII=';
const uri='data:image/png;base64,'+PNG,bytes=Buffer.from(PNG,'base64');
const ref=STORE+'/'+crypto.createHash('sha256').update(bytes).digest('hex')+'.png';
(async()=>{
 const browser=await chromium.launch({executablePath:'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
 try{
  const page=await browser.newPage();const objects=new Map(),requests=[];let mode='',held,release;const errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('https://kenz.invalid/**',r=>r.fulfill({contentType:'text/html',body:'<!doctype html><html><body><div id="images"></div></body></html>'}));
  await page.route('https://test.supabase.co/**',async route=>{
   const request=route.request(),url=new URL(request.url()),key=url.pathname.replace(/^\/storage\/v1\/object\/(authenticated\/)?kenz-model-photos\//,'');
   const headers=request.headers();requests.push({method:request.method(),key,headers});
   assert.equal(headers.apikey,'public-test-key');assert.equal(headers.authorization,'Bearer test-jwt');
   if(request.method()==='POST'){
    assert.equal(headers['x-upsert'],'false');assert.equal(headers['content-type'],'image/png');
    const raw=request.postDataBuffer();assert.equal(crypto.createHash('sha256').update(raw).digest('hex'),key.split('/')[1].split('.')[0]);
    if(objects.has(key))return route.fulfill({status:400,contentType:'application/json',body:'{"error":"Duplicate"}'});
    objects.set(key,{bytes:raw,type:headers['content-type']});
    if(mode==='lost-ack')return route.abort('failed');
    return route.fulfill({contentType:'application/json',body:'{}'});
   }
   if(mode==='hold-read'){held=true;await new Promise(r=>release=r);}
   const record=objects.get(key);if(!record)return route.fulfill({status:404,contentType:'application/json',body:'{}'});
   return route.fulfill({contentType:record.type,body:record.bytes});
  });
  await page.goto('https://kenz.invalid/');
  await page.addScriptTag({content:`const Cloud={url:'https://test.supabase.co',key:'public-test-key',storeId:'${STORE}',epoch:1,session:{user:{id:'owner'}},async token(){return 'test-jwt';}};`});
  await page.addScriptTag({content:fs.readFileSync('photos.js','utf8')});
  const legacy={version:1,items:[{id:'a',photo:uri,quantity:2},{id:'b',photo:uri,quantity:1}],orders:[{id:'o',photo:uri,_sale_request:{id:'keep'}}]};
  const prepared=await page.evaluate(async payload=>Photos.preparePayload(payload),legacy);
  assert.equal(prepared.version,2);assert.equal(prepared.items[0].photo,ref);assert.equal(prepared.orders[0].photo,ref);
  assert.deepEqual(prepared.orders[0]._sale_request,{id:'keep'});assert.equal(legacy.version,1);assert.equal(requests.filter(x=>x.method==='POST').length,1);
  await page.evaluate(()=>Photos.reset());
  const count=requests.length;
  await page.evaluate(async p=>{document.querySelector('#images').innerHTML=Photos.imageMarkup(p,'صورة')+Photos.imageMarkup(p,'صورة');await Photos.refresh();},ref);
  assert.equal(requests.length-count,1,'duplicate image DOM uses one read');
  assert.equal(await page.locator('img[src^="blob:"]').count(),2);
  assert.ok(!(await page.locator('#images').innerHTML()).includes('test-jwt'),'JWT must never enter image DOM');
  const archive=await page.evaluate(async p=>{const result=await Photos.exportBackup(p);return JSON.parse(await result.blob.text());},prepared);
  assert.equal(Object.keys(archive.images).length,1);assert.equal(archive.images[ref],uri);
  await page.evaluate(store=>{Photos.reset();Cloud.storeId=store;Cloud.epoch++;},OTHER);
  const imported=await page.evaluate(async archive=>Photos.importBackup(new File([JSON.stringify(archive)],'backup.json')) ,archive);
  const otherRef=OTHER+'/'+ref.split('/')[1];assert.equal(imported.items[0].photo,otherRef);assert.equal(imported.orders[0].photo,otherRef);assert.ok(objects.has(otherRef));
  const beforeBad=requests.length,bad=structuredClone(archive);bad.images[ref]='data:image/png;base64,AAAA';
  assert.match(await page.evaluate(async bad=>{try{await Photos.importBackup(new File([JSON.stringify(bad)],'bad.json'));return '';}catch(e){return e.message;}},bad),/لا تطابق/);
  assert.equal(requests.length,beforeBad,'corrupt archive is rejected before upload');
  const beforeForeign=requests.length;
  assert.match(await page.evaluate(async ref=>{try{await Photos.preparePayload({version:2,items:[{photo:ref}],orders:[]});return '';}catch(e){return e.message;}},ref),/متجر آخر/);
  assert.equal(requests.length,beforeForeign,'foreign refs cause no remote request');
  await page.evaluate(()=>Photos.reset());mode='lost-ack';objects.delete(otherRef);
  const uncertain=await page.evaluate(async p=>Photos.preparePayload(p),legacy);assert.equal(uncertain.items[0].photo,otherRef);
  assert.equal(requests.at(-1).method,'GET','lost upload acknowledgement reconciled by private hash-verified read');mode='';
  await page.evaluate(()=>Photos.reset());
  const duplicate=await page.evaluate(async p=>Photos.preparePayload(p),legacy);assert.equal(duplicate.items[0].photo,otherRef);assert.equal(requests.at(-1).method,'GET');
  await page.evaluate(()=>Photos.reset());mode='hold-read';
  const stale=page.evaluate(async ref=>{document.querySelector('#images').innerHTML=Photos.imageMarkup(ref,'old');await Photos.refresh();return document.querySelector('img').getAttribute('src');},otherRef);
  while(!held)await new Promise(r=>setTimeout(r,5));
  await page.evaluate(()=>{Cloud.epoch++;Photos.reset();Cloud.session=null;});release();
  assert.equal(await stale,null,'signed-out image fetch must not display private bytes');mode='';
  assert.deepEqual(errors,[]);console.log('PASS photo client: binary/dedup, authenticated rendering, portable archive/remap, corruption, cross-store rejection, duplicate/lost-ack verification, logout race');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
