const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('StayWeb/Resources/StreamingFilter.js', 'utf8');
function fixture(host = 'www.primevideo.com') {
  class XHR {
    open(method, url) { this.url = url; this.readyState = 1; }
    finish(body, type = '') { this.body = body; this.responseType = type; this.readyState = 4; }
    get responseText() { return this.body; }
    get response() { return this.body; }
  }
  const calls = [];
  const ctx = vm.createContext({URL, Response, Request, XMLHttpRequest: XHR,
    location: {protocol: 'https:', hostname: host, href: `https://${host}/`},
    fetch: async (input, init) => {
      calls.push({input, init});
      const response = new Response(JSON.stringify({cuepointPlaylist: {ads: [1]},
        vodPlaybackUrls: {result: {playbackUrls: {cuepoints: [2], manifest: 'keep.mpd'}}}, license: 'keep'}));
      Object.defineProperty(response, 'url', {value: String(input)});
      return response;
    }});
  vm.runInContext('window = globalThis', ctx);
  vm.runInContext(source, ctx);
  return {ctx, calls, XHR};
}
(async () => {
  const {ctx, calls, XHR} = fixture();
  assert.equal(vm.runInContext('__staywebStreamingFilter.version',ctx), 1);
  assert.equal(vm.runInContext(`JSON.parse('{"ordinary":1}').ordinary`,ctx), 1);
  assert.equal(vm.runInContext(`JSON.parse('{"cuepointPlaylist":{},"license":"ok"}').license`,ctx), 'ok');
  assert.equal(vm.runInContext(`'cuepointPlaylist' in JSON.parse('{"cuepointPlaylist":{}}')`,ctx), false);
  const result = await vm.runInContext(`fetch('https://www.primevideo.com/GetPlaybackResources?deviceAdInsertionTypeOverride=SSAI&desiredResources=PlaybackUrls%2CCuepointPlaylist', {credentials:'include',headers:{test:'preserved'}}).then(async r => ({url:r.url,status:r.status,body:await r.clone().json(),text:await r.text()}))`,ctx);
  assert(!calls[0].input.includes('deviceAdInsertionTypeOverride'));
  assert(!calls[0].input.includes('CuepointPlaylist'));
  assert.equal(calls[0].init.credentials, 'include');
  assert.equal(calls[0].init.headers.test, 'preserved');
  assert.equal(result.status, 200);
  assert.equal(result.body.license, 'keep');
  assert.equal(result.body.vodPlaybackUrls.result.playbackUrls.manifest, 'keep.mpd');
  assert(!('cuepointPlaylist' in result.body));
  assert(!('cuepoints' in result.body.vodPlaybackUrls.result.playbackUrls));
  assert(!result.text.includes('cuepointPlaylist'));
  await vm.runInContext(`fetch('https://example.com/GetPlaybackResources?deviceAdInsertionTypeOverride=x')`,ctx);
  assert.equal(calls[1].input, 'https://example.com/GetPlaybackResources?deviceAdInsertionTypeOverride=x');
  const xhr = new XHR();
  xhr.open('GET','https://www.primevideo.com/GetPlaybackResources?deviceAdInsertionTypeOverride=x');
  xhr.finish('{"cuepointPlaylist":{},"video":"ok"}');
  assert.equal(JSON.parse(xhr.responseText).video, 'ok');
  assert(!xhr.responseText.includes('cuepointPlaylist'));
  xhr.finish({cuepointPlaylist:{}, video:'ok'}, 'json');
  assert.equal(xhr.response.video, 'ok');
  assert(!('cuepointPlaylist' in xhr.response));
  xhr.open('GET','https://example.com/normal'); xhr.finish('{"cuepointPlaylist":{}}');
  assert.equal(xhr.responseText, '{"cuepointPlaylist":{}}');
  const offsite = fixture('primevideo.com.evil.example').ctx;
  assert.equal(vm.runInContext('typeof __staywebStreamingFilter',offsite),'undefined');
  for (const [host, input, removed] of [
    ['www.disneyplus.com', {ads:{metadata:{},vod:{},keep:'ok'},video:'ok'}, 'ads'],
    ['www.hulu.com', {breaks:[],custom_breaks_data:{},pause_ads:[],video:'ok'}, 'breaks'],
    ['www.peacocktv.com', {avails:[],nonLinearAvails:[],nextToken:'ad',video:'ok'}, 'avails']
  ]) {
    const f = fixture(host).ctx;
    f.fixtureJSON = JSON.stringify(input);
    const filtered = vm.runInContext('JSON.parse(fixtureJSON)',f);
    assert.equal(filtered.video,'ok');
    if (removed === 'ads') { assert.equal(filtered.ads.keep,'ok'); assert(!('vod' in filtered.ads)); }
    else assert(!(removed in filtered));
    const regular = vm.runInContext(`JSON.parse('{"nextToken":"keep","video":"ok"}')`,f);
    assert.equal(regular.nextToken,'keep');
  }
  console.log('PASS: Prime scope, fetch/clone/text/json, request credentials, XHR text/json and unrelated response preservation');
})().catch(e => { console.error(e); process.exit(1); });
