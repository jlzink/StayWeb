/* StayWeb streaming compatibility filters. See FilterCredits.txt. */
(() => {
  'use strict';
  const service = ['primevideo.com', 'disneyplus.com', 'hulu.com', 'peacocktv.com'].find(
    domain => location.hostname === domain || location.hostname.endsWith('.' + domain));
  if (location.protocol !== 'https:' || !service) return;
  if (window.__staywebStreamingFilter) return;
  const nativeParse = JSON.parse;
  const state = {version: 1, service, requests: 0, responses: 0};
  Object.defineProperty(window, '__staywebStreamingFilter', {value: state});
  function playbackURL(value) {
    try {
      const u = new URL(value, location.href);
      return u.protocol === 'https:' && /(^|\.)primevideo\.com$/.test(u.hostname) && /\/GetPlaybackResources$/i.test(u.pathname);
    } catch (_) { return false; }
  }
  function cleanURL(value) {
    if (service !== 'primevideo.com' || !playbackURL(value)) return value;
    const u = new URL(value, location.href);
    let changed = u.searchParams.has('deviceAdInsertionTypeOverride');
    u.searchParams.delete('deviceAdInsertionTypeOverride');
    // Avoid rewriting signed or unrelated URLs; only this playback API is eligible.
    for (const [key, val] of [...u.searchParams]) {
      if (key.toLowerCase() === 'desiredresources') {
        const items = val.split(',').filter(x => x !== 'CuepointPlaylist');
        if (items.length && items.join(',') !== val) { u.searchParams.set(key, items.join(',')); changed = true; }
      }
    }
    if (!changed) return value;
    const result = u.href;
    if (result !== String(value)) state.requests++;
    return result;
  }
  function pruneJSON(value) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return value;
    let changed = false;
    const paths = {
      'primevideo.com': ['cuepointPlaylist', 'vodPlaybackUrls.result.playbackUrls.cuepoints'],
      'disneyplus.com': ['ads.metadata', 'ads.document', 'ads.dxc', 'ads.live', 'ads.vod'],
      'hulu.com': ['breaks', 'custom_breaks_data', 'pause_ads'],
      'peacocktv.com': ['avails', 'dashAvailabilityStartTime', 'hlsAnchorMediaSequenceNumber', 'nextToken', 'nonLinearAvails']
    }[service];
    // Peacock's paging/timing fields are removed only alongside its ad avails.
    if (service === 'peacocktv.com' && !('avails' in value || 'nonLinearAvails' in value)) return value;
    for (const path of paths) {
      const keys = path.split('.'), last = keys.pop();
      let target = value;
      for (const key of keys) target = target && typeof target === 'object' ? target[key] : undefined;
      if (target && typeof target === 'object' && Object.prototype.hasOwnProperty.call(target, last)) {
        delete target[last]; changed = true;
      }
    }
    if (changed) state.responses++;
    return value;
  }
  function pruneMPD(text) {
    if (!['primevideo.com', 'hulu.com'].includes(service)) return text;
    if (!text.includes('<') || !text.includes('MPD')) return text;
    const doc = new DOMParser().parseFromString(text, 'application/xml');
    if (doc.getElementsByTagName('parsererror').length || doc.documentElement.localName !== 'MPD') return text;
    const periods = [...doc.getElementsByTagNameNS('*', 'Period')];
    const ads = periods.filter(p => service === 'hulu.com' ?
      (/^ad/i.test(p.getAttribute('id') || '') || [...p.getElementsByTagNameNS('*', 'BaseURL')].some(e => e.textContent.includes('/ads-'))) :
      [...p.getElementsByTagName('*')].some(e =>
      (e.localName === 'BaseURL' && e.textContent.includes('/interstitial/')) ||
      (['Ad', 'Draper'].includes(e.getAttribute('value')) && /Descriptor|Property|Role/.test(e.localName))));
    if (!ads.length || ads.length === periods.length) return text;
    ads.forEach(p => p.remove());
    doc.documentElement.removeAttribute('mediaPresentationDuration');
    periods.filter(p => !ads.includes(p)).forEach(p => p.removeAttribute('start'));
    state.responses++;
    return new XMLSerializer().serializeToString(doc);
  }
  function transform(text, url) {
    if (typeof text !== 'string' || text.length > 8 * 1024 * 1024) return text;
    try {
      if (playbackURL(url) || (service !== 'primevideo.com' && /^\s*\{/.test(text))) {
        const value = nativeParse(text), before = state.responses;
        pruneJSON(value);
        return before === state.responses ? text : JSON.stringify(value);
      }
      if (/\.mpd(?:[?#]|$)/i.test(url)) return pruneMPD(text);
    } catch (_) {}
    return text;
  }
  // JSON.parse handles XHR text parsing; fetch .json() is handled below.
  JSON.parse = new Proxy(nativeParse, {apply(target, receiver, args) {
    return pruneJSON(Reflect.apply(target, receiver, args));
  }});
  const originalFetch = window.fetch;
  if (originalFetch) window.fetch = async function(input, init) {
    let next = input;
    // Do not reconstruct Request objects: preserve bodies, signatures and stream semantics.
    if (typeof input === 'string' || input instanceof URL) next = cleanURL(String(input));
    const response = await Reflect.apply(originalFetch, this, [next, init]);
    const url = response.url || (typeof next === 'string' ? next : next.url);
    if (service === 'primevideo.com' && !playbackURL(url) && !/\.mpd(?:[?#]|$)/i.test(url)) return response;
    // Keep the native Response (status, URL, headers, body and prototype intact).
    // Only the player's text/json reads use the transformed representation.
    function decorate(r) {
      const read = r.text.bind(r), copy = r.clone.bind(r);
      r.text = async () => transform(await read(), url);
      r.json = async () => pruneJSON(nativeParse(await r.text()));
      r.clone = () => decorate(copy());
      return r;
    }
    return decorate(response);
  };
  const proto = XMLHttpRequest.prototype;
  const originalOpen = proto.open;
  const responseDescriptor = Object.getOwnPropertyDescriptor(proto, 'response');
  const textDescriptor = Object.getOwnPropertyDescriptor(proto, 'responseText');
  const urls = new WeakMap();
  proto.open = function(method, url, ...rest) {
    const next = cleanURL(String(url));
    urls.set(this, next);
    return Reflect.apply(originalOpen, this, [method, next, ...rest]);
  };
  if (textDescriptor?.get && textDescriptor.configurable) Object.defineProperty(proto, 'responseText', {
    ...textDescriptor, get() {
      const value = Reflect.apply(textDescriptor.get, this, []);
      return this.readyState === 4 ? transform(value, urls.get(this) || '') : value;
    }
  });
  if (responseDescriptor?.get && responseDescriptor.configurable) Object.defineProperty(proto, 'response', {
    ...responseDescriptor, get() {
      const value = Reflect.apply(responseDescriptor.get, this, []);
      if (this.readyState !== 4) return value;
      const url = urls.get(this) || '';
      if (this.responseType === 'json' && (playbackURL(url) || service !== 'primevideo.com')) return pruneJSON(value);
      return typeof value === 'string' ? transform(value, url) : value;
    }
  });
})();
