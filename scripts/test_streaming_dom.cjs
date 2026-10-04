const {JSDOM} = require('jsdom');
const fs = require('node:fs'), assert = require('node:assert/strict');
const source = fs.readFileSync('StayWeb/Resources/StreamingFilter.js','utf8');
async function setup(host,body) {
  const dom = new JSDOM('', {url:`https://${host}/`,runScripts:'outside-only'});
  dom.window.fetch = async () => new Response(body);
  dom.window.eval(source);
  return dom.window;
}
(async () => {
 for (const [host,body,expect] of [
 ['www.disneyplus.com',{ads:{vod:{},metadata:{},keep:1},movie:'keep'},x=>x.ads.keep===1&&!('vod' in x.ads)],
 ['www.hulu.com',{breaks:[],pause_ads:[],movie:'keep'},x=>!('breaks' in x)],
 ['www.peacocktv.com',{avails:[],nextToken:'ad',movie:'keep'},x=>!('avails' in x)&&!('nextToken' in x)]]) {
   const w=await setup(host,JSON.stringify(body));
   const response=await w.fetch('https://api.example/playback');
   const x=await response.clone().json();
   assert(expect(x)); assert.equal(x.movie,'keep');
   assert(expect(JSON.parse(await response.text())));
   w.close();
 }
 for(const host of ['www.hulu.com','www.primevideo.com']) {
   const marker=host.includes('hulu')?'id="Ad-0"':'';
   const role=host.includes('hulu')?'':'<SupplementalProperty value="Draper"/>';
   const xml=`<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" mediaPresentationDuration="PT90S"><Period ${marker} start="PT0S">${role}<BaseURL>ad.mp4</BaseURL></Period><Period start="PT30S"><ContentProtection schemeIdUri="keep"/><BaseURL>movie.mp4</BaseURL></Period></MPD>`;
   const w=await setup(host,xml),r=await w.fetch('https://cdn.example/movie.mpd');
   const text=await r.text();
   assert(!text.includes('ad.mp4')); assert(text.includes('movie.mp4'));assert(text.includes('ContentProtection'));
   const doc=new w.DOMParser().parseFromString(text,'application/xml');
   assert.equal(doc.getElementsByTagNameNS('*','Period').length,1);
   assert(!doc.documentElement.hasAttribute('mediaPresentationDuration'));
   w.close();
 }
 console.log('PASS: Disney/Hulu/Peacock fetch text+JSON+clone; Hulu/Prime namespaced XML ad-period pruning preserves movie and DRM metadata');
})().catch(e=>{console.error(e);process.exit(1)});
