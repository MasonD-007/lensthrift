// Run: node --test web/tests/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const { pickTarget, iou, createStabilizer, HOLD_MS } = createRequire(import.meta.url)('../stabilize.js');

const det = (label, box, conf = 0.8) => ({ label, conf, box });
const CENTER = [0.4, 0.4, 0.6, 0.6];

test('hold time is about 2 seconds', () => {
  assert.equal(HOLD_MS, 2000);
});

test('pickTarget ignores people', () => {
  assert.equal(pickTarget([det('person', [0.1, 0.0, 0.9, 1.0])]), null);
  assert.equal(pickTarget([det('person', [0.1, 0.0, 0.9, 1.0]), det('cup', CENTER)]).label, 'cup');
});

test('pickTarget prefers the centered object over a bigger one at the edge', () => {
  const edge = det('vase', [0.0, 0.0, 0.4, 0.4]);
  const middle = det('cup', CENTER);
  assert.equal(pickTarget([edge, middle]).label, 'cup');
});

test('pickTarget prefers the closer (bigger) object when both are centered', () => {
  const far = det('cup', [0.45, 0.45, 0.55, 0.55]);
  const near = det('bowl', [0.3, 0.3, 0.7, 0.7]);
  assert.equal(pickTarget([far, near]).label, 'bowl');
});

test('a new object only takes over when it is clearly a better target', () => {
  const s = createStabilizer();
  s.update([det('cup', [0.35, 0.35, 0.55, 0.55])], 0);
  // a slightly better-placed bowl appears: keep counting on the cup
  const r = s.update([det('cup', [0.35, 0.35, 0.55, 0.55]), det('bowl', [0.42, 0.42, 0.6, 0.6])], 500);
  assert.equal(r.target.label, 'cup');
  // one missed cup detection doesn't hand the countdown to the bowl
  assert.equal(s.update([det('bowl', [0.42, 0.42, 0.6, 0.6])], 600).target.label, 'cup');
  // the cup is really gone: the bowl starts its own countdown
  const t = s.update([det('bowl', [0.42, 0.42, 0.6, 0.6])], 1200);
  assert.equal(t.target.label, 'bowl');
  assert.equal(t.progress, 0);
});

test('pickTarget returns null for no detections', () => {
  assert.equal(pickTarget([]), null);
});

test('iou of identical boxes is 1 and of disjoint boxes is 0', () => {
  assert.equal(iou(CENTER, CENTER), 1);
  assert.equal(iou([0, 0, 0.1, 0.1], [0.5, 0.5, 0.6, 0.6]), 0);
});

test('an object held still becomes stabilized after 2 s, not before', () => {
  const s = createStabilizer();
  assert.equal(s.update([det('cup', CENTER)], 0).phase, 'stabilizing');
  const almost = s.update([det('cup', CENTER)], 1999);
  assert.equal(almost.phase, 'stabilizing');
  assert.ok(almost.progress > 0.99 && almost.progress < 1);
  const done = s.update([det('cup', CENTER)], 2000);
  assert.equal(done.phase, 'stabilized');
  assert.equal(done.target.label, 'cup');
  assert.equal(done.progress, 1);
});

test('nothing in view is searching', () => {
  const r = createStabilizer().update([], 0);
  assert.equal(r.phase, 'searching');
  assert.equal(r.target, null);
  assert.equal(r.progress, 0);
});

test('moving the object restarts the countdown', () => {
  const s = createStabilizer();
  s.update([det('cup', CENTER)], 0);
  s.update([det('cup', CENTER)], 1500);
  const moved = s.update([det('cup', [0.6, 0.6, 0.8, 0.8])], 1600);
  assert.equal(moved.phase, 'stabilizing');
  assert.equal(moved.progress, 0);
});

test('small jitter and a flickering label keep the countdown going', () => {
  const s = createStabilizer();
  s.update([det('cup', CENTER)], 0);
  s.update([det('vase', [0.41, 0.4, 0.61, 0.6])], 1000);
  assert.equal(s.update([det('cup', [0.4, 0.41, 0.6, 0.61])], 2000).phase, 'stabilized');
});

test('a brief detection miss is tolerated, a long one resets', () => {
  const s = createStabilizer();
  s.update([det('cup', CENTER)], 0);
  s.update([det('cup', CENTER)], 900);
  assert.equal(s.update([], 1200).phase, 'stabilizing'); // 300 ms miss
  s.update([det('cup', CENTER)], 1800);
  // only sends on a frame where the object is actually seen
  assert.equal(s.update([], 2100).phase, 'stabilizing');
  assert.equal(s.update([det('cup', CENTER)], 2200).phase, 'stabilized');

  const t = createStabilizer();
  t.update([det('cup', CENTER)], 0);
  assert.equal(t.update([], 700).phase, 'searching');
});

test('after sending, the same held object stays quiet until something else is held', () => {
  const s = createStabilizer();
  s.update([det('cup', CENTER)], 0);
  assert.equal(s.update([det('cup', CENTER)], 2000).phase, 'stabilized');
  s.markSent();
  assert.equal(s.update([det('cup', CENTER)], 2500).phase, 'sent');
  assert.equal(s.update([det('cup', CENTER)], 9000).phase, 'sent');
  assert.equal(s.update([det('bowl', [0.1, 0.1, 0.3, 0.3])], 9100).phase, 'sent'); // cup only just missed
  const next = s.update([det('bowl', [0.1, 0.1, 0.3, 0.3])], 9700);
  assert.equal(next.phase, 'stabilizing');
  assert.equal(next.target.label, 'bowl');
});

test('the same object leaving and coming back is scanned again', () => {
  const s = createStabilizer();
  s.update([det('cup', CENTER)], 0);
  s.update([det('cup', CENTER)], 2000);
  s.markSent();
  s.update([], 3000); // gone longer than the miss tolerance
  assert.equal(s.update([det('cup', CENTER)], 3100).phase, 'stabilizing');
});

test('a clearly better-placed object takes over right away', () => {
  const s = createStabilizer();
  s.update([det('cup', [0.0, 0.0, 0.3, 0.3])], 0);
  const r = s.update([det('cup', [0.0, 0.0, 0.3, 0.3]), det('bowl', CENTER)], 500);
  assert.equal(r.target.label, 'bowl');
  assert.equal(r.progress, 0);
});
