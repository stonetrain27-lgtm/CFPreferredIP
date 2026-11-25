import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../worker/subscription/worker.js', import.meta.url), 'utf8');
const { default: worker } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);

const vmess = 'vmess://' + Buffer.from(JSON.stringify({ v: '2', ps: 'vm-LAX-1', add: '1.2.3.4', port: '443', id: 'u2', aid: '0', net: 'ws', tls: 'tls', sni: 'a.example.com', host: 'a.example.com', path: '/vm' })).toString('base64');
const content = [
  'vless://11111111-1111-4111-8111-111111111111@1.2.3.4:443?type=ws&security=tls&sni=a.example.com&host=a.example.com&path=%2F%3Fed%3D2560&fp=chrome#vl-LAX-1',
  'trojan://pw@1.2.3.5:443?type=ws&security=tls&sni=a.example.com&host=a.example.com&path=%2Ft#tr-LAX-2',
  vmess,
  'vless://x@1.2.3.6:443?type=xhttp&security=tls&sni=a.example.com#xh-unsupported',
  'ss://' + Buffer.from('aes-128-gcm:pass').toString('base64') + '@1.2.3.7:8388#ss1',
].join('\n') + '\n';

const store = new Map([['subscription-content', content]]);
const env = { SUB_PATH_KEY: 'k', UPDATE_SECRET: 's', SUBSCRIPTION_KV_KEY: 'subscription-content',
  SUBSCRIPTION_KV: { async get(k) { return store.get(k) ?? null; }, async put() {} } };
const get = async (q, ua) => worker.fetch(new Request(`https://x.test/k${q}`, { headers: ua ? { 'User-Agent': ua } : {} }), env);

assert.equal(await (await get('')).text(), content, 'default stays plain');
assert.equal(Buffer.from(await (await get('?target=base64')).text(), 'base64').toString(), content, 'base64 round-trips');

const clash = await (await get('?target=clash')).text();
assert.match(clash, /^proxies:/m);
assert.equal((clash.match(/^  - \{"name":"(vl|tr|vm|ss)/gm) || []).length, 4, 'clash has 4 supported nodes, xhttp skipped');
assert.ok(clash.includes('"path":"/?ed=2560"'), 'ws path decoded');
assert.ok(!clash.includes('xh-unsupported'));
assert.equal(await (await get('', 'clash.meta/1.18')).text(), clash, 'UA picks clash');

const sb = JSON.parse(await (await get('?target=singbox')).text());
assert.equal(sb.outbounds.filter((o) => ['vless', 'vmess', 'trojan', 'shadowsocks'].includes(o.type)).length, 4);
assert.equal(sb.outbounds.find((o) => o.tag === 'vl-LAX-1').transport.type, 'ws');

const surge = await (await get('?target=surge')).text();
assert.ok(surge.includes('tr-LAX-2 = trojan, 1.2.3.5, 443'));
assert.ok(surge.includes('vm-LAX-1 = vmess'));
assert.ok(!surge.includes('vl-LAX-1'), 'surge skips vless');
console.log('worker multi-client conversion: passed');
