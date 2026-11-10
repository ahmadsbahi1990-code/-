/* Private, immutable image storage. No public object URLs or credentials enter the DOM. */
const Photos=(()=>{
 'use strict';
 const BUCKET='kenz-model-photos',MAX_IMAGE=1048576,MAX_METADATA=10485760,MAX_BACKUP=104857600;
 const REF=/^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/([0-9a-f]{64})\.(jpg|png|webp)$/;
 const INLINE=/^data:image\/(jpeg|png|webp);base64,([A-Za-z0-9+/]+={0,2})$/;
 const TYPES={jpg:'image/jpeg',png:'image/png',webp:'image/webp'},EXT={'image/jpeg':'jpg','image/png':'png','image/webp':'webp'};
 let generation=0,scope='',active=0;const pending=[],controllers=new Set(),cache=new Map(),reads=new Map(),uploads=new Map();
 const escape=v=>String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const isReference=v=>typeof v==='string'&&REF.test(v);
 const isInline=v=>typeof v==='string'&&v.length<=400000&&INLINE.test(v);
 const changed=()=>Error('تغيّرت جلسة الدخول أو المتجر. أعد فتح البيانات.');
 function reset(){generation++;scope='';for(const c of controllers)c.abort();controllers.clear();for(const v of cache.values())if(v.url)URL.revokeObjectURL(v.url);cache.clear();reads.clear();uploads.clear();for(const next of pending.splice(0))next.reject(changed());document.querySelectorAll('img[data-kenz-photo]').forEach(img=>{img.removeAttribute('src');});}
 function context(value={}){
  const storeId=value.storeId??Cloud.storeId,epoch=value.epoch??Cloud.epoch,key=epoch+':'+storeId;
  if(!Cloud.session||epoch!==Cloud.epoch||storeId!==Cloud.storeId||!REF.test(storeId+'/'+'0'.repeat(64)+'.jpg'))throw changed();
  if(scope&&scope!==key)reset();scope=key;
  return {...value,storeId,epoch,generation};
 }
 function guard(c){if(c.generation!==generation||!Cloud.session||c.epoch!==Cloud.epoch||c.storeId!==Cloud.storeId)throw changed();}
 async function slot(c){guard(c);if(active<4){active++;return;}await new Promise((resolve,reject)=>pending.push({resolve,reject,c}));try{guard(c);}catch(error){release();throw error;}}
 function release(){active--;while(pending.length){const n=pending.shift();try{guard(n.c);active++;n.resolve();break;}catch(e){n.reject(e);}}}
 async function request(method,ref,body,type,c){
  guard(c);if(!isReference(ref)||!ref.startsWith(c.storeId+'/'))throw Error('مرجع الصورة لا يخص هذا المتجر.');
  await slot(c);let controller,timer;
  try{
   for(let attempt=0;attempt<2;attempt++){
    guard(c);const token=await Cloud.token(attempt===1);guard(c);
    controller=new AbortController();controllers.add(controller);timer=setTimeout(()=>controller.abort(),30000);
    let response;
    try{response=await fetch(Cloud.url+'/storage/v1/object/'+(method==='GET'?'authenticated/':'')+BUCKET+'/'+ref,{method,headers:{apikey:Cloud.key,Authorization:'Bearer '+token,...(method==='POST'?{'Content-Type':type,'x-upsert':'false'}:{})},body,signal:controller.signal,cache:'no-store'});guard(c);
     if(response.status===401&&attempt===0){await response.text();guard(c);continue;}
     if(!response.ok){let info;try{info=await response.json();}catch{}guard(c);const error=Error(response.status===403?'لا تملك صلاحية الوصول إلى الصور.':'تعذّر '+(method==='GET'?'تحميل':'رفع')+' الصورة. تحقّق من الاتصال وحاول مجدداً.');error.status=response.status;error.code=info?.error||info?.code||info?.statusCode||'';throw error;}
     if(method==='GET'){const bytes=new Uint8Array(await response.arrayBuffer());guard(c);return {bytes,type:(response.headers.get('Content-Type')||'').split(';')[0].toLowerCase()};}
     await response.text();guard(c);return null;
    }finally{clearTimeout(timer);controllers.delete(controller);}
   }
  }catch(e){guard(c);if(e.name==='AbortError')throw Error('انتهت مهلة رفع أو تحميل الصورة. لم تتغيّر بيانات المخزون.');throw e;}
  finally{release();}
 }
 async function digest(bytes,c){const value=await crypto.subtle.digest('SHA-256',bytes);guard(c);return Array.from(new Uint8Array(value),v=>v.toString(16).padStart(2,'0')).join('');}
 function decode(uri){
  if(typeof uri!=='string'||uri.length>Math.ceil(MAX_IMAGE/3)*4+40||!INLINE.test(uri))throw Error('صيغة الصورة غير صالحة.');const m=INLINE.exec(uri),raw=atob(m[2]),bytes=Uint8Array.from(raw,c=>c.charCodeAt(0));
  if(!bytes.length||bytes.length>MAX_IMAGE)throw Error('الصورة تتجاوز المساحة المسموحة للصورة الواحدة.');return {bytes,type:'image/'+m[1]};
 }
 async function verify(ref,record,c){
  const m=REF.exec(ref);if(!m||record.type!==TYPES[m[3]]||!record.bytes.length||record.bytes.length>MAX_IMAGE||await digest(record.bytes,c)!==m[2])throw Error('الصورة المخزّنة لا تطابق مرجعها. لم تتغيّر بيانات المخزون.');guard(c);return record;
 }
 function remember(ref,record,c){guard(c);const existing=cache.get(ref);if(existing)return existing;const value={...record,url:URL.createObjectURL(new Blob([record.bytes],{type:record.type}))};cache.set(ref,value);return value;}
 async function read(ref,c){
  guard(c);if(cache.has(ref))return cache.get(ref);if(reads.has(ref))return reads.get(ref);
  const job=(async()=>remember(ref,await verify(ref,await request('GET',ref,undefined,undefined,c),c),c))();reads.set(ref,job);
  try{return await job;}finally{if(reads.get(ref)===job)reads.delete(ref);}
 }
 async function upload(uri,c){return uploadRecord(decode(uri),c);}
 async function uploadRecord(record,c){
  guard(c);const ref=c.storeId+'/'+await digest(record.bytes,c)+'.'+EXT[record.type];guard(c);
  if(cache.has(ref))return ref;if(uploads.has(ref))return uploads.get(ref);
  const job=(async()=>{
   try{await request('POST',ref,record.bytes,record.type,c);remember(ref,record,c);}
   catch(error){guard(c);const duplicate=error.status===409||(error.status===400&&/duplicate|already.?exists|resource.?exists/i.test(String(error.code)));
    if(!duplicate&&error.status&&error.status<500)throw error;
    // A lost upload acknowledgement is safe to reconcile: the immutable name is the byte hash.
    try{await read(ref,c);}catch(check){guard(c);if(check.status===404)throw error;throw check;}
   }guard(c);return ref;
  })();uploads.set(ref,job);try{return await job;}finally{if(uploads.get(ref)===job)uploads.delete(ref);}
 }
 function records(payload){if(!payload||![1,2].includes(payload.version)||!Array.isArray(payload.items)||!Array.isArray(payload.orders))throw Error('صيغة النسخة غير صالحة.');return [...payload.items,...payload.orders];}
 function metadataLimit(payload){if(new Blob([JSON.stringify(payload)]).size>MAX_METADATA)throw Error('بيانات المخزون تتجاوز الحد المسموح.');}
 async function preparePayload(payload,value={}){
  const c=context(value),copy=JSON.parse(JSON.stringify(payload)),list=records(copy),unique=[...new Set(list.map(r=>r?.photo).filter(Boolean))];let completed=0;
  const converted=new Map();for(const photo of unique){guard(c);let ref;
   if(isInline(photo))ref=await upload(photo,c);
   else if(isReference(photo)&&photo.startsWith(c.storeId+'/'))ref=photo;
   else throw Error('صورة غير صالحة أو تابعة لمتجر آخر. استخدم نسخة احتياطية كاملة بالصور.');
   converted.set(photo,ref);guard(c);c.onProgress?.(++completed,unique.length);
  }
  for(const row of list)if(row.photo)row.photo=converted.get(row.photo);copy.version=2;metadataLimit(copy);guard(c);return copy;
 }
 function imageMarkup(photo,label){if(!photo)return '<span class="placeholder">♧</span>';if(isInline(photo))return '<img src="'+escape(photo)+'" alt="'+escape(label)+'" loading="lazy">';if(isReference(photo))return '<img data-kenz-photo="'+escape(photo)+'" alt="'+escape(label)+'" loading="lazy">';return '<span class="placeholder">♧</span>';}
 function show(target,photo){const img=typeof target==='string'?document.querySelector(target):target;if(!img)return;img.removeAttribute('data-kenz-photo');img.removeAttribute('src');img.hidden=!photo;if(!photo)return;if(isInline(photo)){img.src=photo;return;}if(isReference(photo)){img.dataset.kenzPhoto=photo;refresh(img);}else img.hidden=true;}
 function refresh(root=document){
  const images=[...(root.matches?.('img[data-kenz-photo]')?[root]:[]),...root.querySelectorAll('img[data-kenz-photo]')];let c;try{c=context();}catch{return Promise.resolve();}
  return Promise.allSettled(images.map(async img=>{const ref=img.dataset.kenzPhoto;try{const record=await read(ref,c);guard(c);if(img.isConnected&&img.dataset.kenzPhoto===ref){img.src=record.url;img.title='';}}catch(error){if(c.generation===generation&&c.epoch===Cloud.epoch&&img.isConnected&&img.dataset.kenzPhoto===ref){img.removeAttribute('src');img.title=error.message;}}}));
 }
 function encode(record){let binary='';for(let i=0;i<record.bytes.length;i+=32768)binary+=String.fromCharCode(...record.bytes.subarray(i,i+32768));return 'data:'+record.type+';base64,'+btoa(binary);}
 async function exportBackup(payload,value={}){
  const c=context(value),copy=JSON.parse(JSON.stringify(payload)),images=Object.create(null),list=records(copy),unique=[...new Set(list.map(r=>r?.photo).filter(Boolean))];let completed=0;
  if(copy.version===1){const blob=new Blob([JSON.stringify(copy,null,2)],{type:'application/json'});guard(c);return {blob,filename:'kenz-backup-'+new Date().toISOString().slice(0,10)+'.json'};}
  metadataLimit(copy);
  for(const ref of unique){if(!isReference(ref)||!ref.startsWith(c.storeId+'/'))throw Error('مرجع صورة غير صالح.');images[ref]=encode(await read(ref,c));guard(c);c.onProgress?.(++completed,unique.length);}
  const blob=new Blob([JSON.stringify({format:'kenz-backup',version:2,payload:copy,images})],{type:'application/json'});if(blob.size>MAX_BACKUP)throw Error('النسخة الاحتياطية تتجاوز 100 ميغابايت.');guard(c);return {blob,filename:'kenz-backup-'+new Date().toISOString().slice(0,10)+'.json'};
 }
 async function importBackup(file,value={}){
  const c=context(value);if(!file||file.size>MAX_BACKUP)throw Error('النسخة الاحتياطية تتجاوز 100 ميغابايت.');const text=await file.text();guard(c);let archive;try{archive=JSON.parse(text);}catch{throw Error('ملف النسخة الاحتياطية غير صالح.');}
  if(archive?.version===1&&!archive.format)return preparePayload(archive,c);
  if(archive?.format!=='kenz-backup'||archive.version!==2||archive.payload?.version!==2||!archive.images||typeof archive.images!=='object'||Array.isArray(archive.images))throw Error('استخدم نسخة احتياطية كاملة بالصور، أو نسخة قديمة من الإصدار الأول.');
  const copy=JSON.parse(JSON.stringify(archive.payload)),list=records(copy),unique=[...new Set(list.map(r=>r?.photo).filter(Boolean))];metadataLimit(copy);
  // Verify the complete archive before the first upload. Invalid backups cannot partially alter metadata.
  for(const ref of unique){if(!isReference(ref)||!Object.hasOwn(archive.images,ref))throw Error('صورة مفقودة من النسخة الاحتياطية.');await verify(ref,decode(archive.images[ref]),c);}
  const converted=new Map();let completed=0;for(const ref of unique){converted.set(ref,await uploadRecord(decode(archive.images[ref]),c));guard(c);c.onProgress?.(++completed,unique.length);}
  for(const row of list)if(row.photo)row.photo=converted.get(row.photo);metadataLimit(copy);guard(c);return copy;
 }
 return {isReference,isInline,imageMarkup,show,refresh,reset,preparePayload,uploadLegacy:preparePayload,exportBackup,importBackup};
})();
