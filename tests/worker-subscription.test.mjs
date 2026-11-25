import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../worker/subscription/worker.js', import.meta.url), 'utf8');
const { default: worker } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);

const values = new Map();
const env = {
  SUB_PATH_KEY: 'public-path-secret',
  UPDATE_SECRET: 'private-update-secret',
  SUBSCRIPTION_KV_KEY: 'subscription-content',
  SUBSCRIPTION_KV: {
    async put(key, value) { values.set(key, Buffer.from(value).toString('utf8')); },
    async get(key) { return values.has(key) ? values.get(key) : null; }
  }
};

async function call(path, init = {}, bindings = env) {
  return worker.fetch(new Request(`https://sub.example.test${path}`, init), bindings);
}

let response = await call('/wrong');
assert.equal(response.status, 404, 'unknown public path is hidden');

response = await call('/_update', { method: 'PUT', body: 'node://unauthorized' });
assert.equal(response.status, 404, 'unauthorized update is hidden');

response = await call('/_update', {
  method: 'PUT',
  headers: { Authorization: 'Bearer private-update-secret' },
  body: 'vless://uuid@example.com:443?security=tls\ntrojan://pw@example.com:443\n'
});
assert.equal(response.status, 204, 'authorized update succeeds');

response = await call('/public-path-secret');
assert.equal(response.status, 200, 'public secret path is readable');
assert.equal(await response.text(), 'vless://uuid@example.com:443?security=tls\ntrojan://pw@example.com:443\n');
assert.equal(response.headers.get('cache-control'), 'no-store, private, max-age=0');
assert.equal(response.headers.get('content-type'), 'text/plain; charset=utf-8');
assert.equal(response.headers.get('x-content-type-options'), 'nosniff');

response = await call('/_update', {
  method: 'PUT',
  headers: { Authorization: 'Bearer private-update-secret' },
  body: ''
});
assert.equal(response.status, 400, 'empty updates are rejected');

response = await call('/_update', {
  method: 'PUT',
  headers: { Authorization: 'Bearer private-update-secret' },
  body: Buffer.alloc(512 * 1024 + 1)
});
assert.equal(response.status, 413, 'oversized updates are rejected');

const malformedLengthRequest = {
  url: 'https://sub.example.test/_update',
  method: 'PUT',
  headers: new Headers({ Authorization: 'Bearer private-update-secret', 'Content-Length': 'nope' }),
  body: new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode('x')); controller.close(); } })
};
response = await worker.fetch(malformedLengthRequest, env);
assert.equal(response.status, 400, 'malformed Content-Length is rejected');

const noKV = { ...env, SUBSCRIPTION_KV: undefined };
response = await call('/public-path-secret', {}, noKV);
assert.equal(response.status, 503, 'missing KV binding reports unavailable');

const brokenKV = { ...env, SUBSCRIPTION_KV: { async get() { throw new Error('offline'); } } };
response = await call('/public-path-secret', {}, brokenKV);
assert.equal(response.status, 503, 'KV read failure reports unavailable');


const mismatchedLengthRequest = {
  url: 'https://sub.example.test/_update',
  method: 'PUT',
  headers: new Headers({ Authorization: 'Bearer private-update-secret', 'Content-Length': '2' }),
  body: new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode('one')); controller.close(); } })
};
response = await worker.fetch(mismatchedLengthRequest, env);
assert.equal(response.status, 400, 'Content-Length mismatch is rejected');

const brokenPutKV = { ...env, SUBSCRIPTION_KV: { async put() { throw new Error('offline'); } } };
response = await call('/_update', {
  method: 'PUT',
  headers: { Authorization: 'Bearer private-update-secret' },
  body: 'new nodes'
}, brokenPutKV);
assert.equal(response.status, 503, 'KV write failure reports unavailable');

const missingPublicSecret = { ...env, SUB_PATH_KEY: '' };
response = await call('/public-path-secret', {}, missingPublicSecret);
assert.equal(response.status, 404, 'missing public secret remains hidden');

console.log('Worker subscription tests: 16 assertions passed');
