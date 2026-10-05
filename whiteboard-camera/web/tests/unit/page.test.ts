import { test } from "node:test";
import assert from "node:assert/strict";
import { PageFollow } from "../../src/page.js";

/** Deterministic page ids: 16 bytes, all equal to a counter. */
function ids(): () => Uint8Array {
  let n = 0;
  return () => new Uint8Array(16).fill(++n);
}

test("a fresh page starts at index 0 with an id, and New page asks for index 1 without moving yet", () => {
  const page = new PageFollow(ids());
  assert.equal(page.pageIndex, 0);
  assert.equal(page.pageId[0], 1);
  const next = page.next();
  assert.equal(next.index, 1);
  assert.equal(page.pageIndex, 0, "a refused PAGE_CHANGE leaves the page as it was");
  assert.equal(page.pageId[0], 1);
  page.committed(next);
  assert.equal(page.pageIndex, 1);
  assert.equal(page.pageId, next.id);
  assert.equal(page.pending, true);
});

test("STATE with another page_index moves the local index there and gives the page a new id", () => {
  const page = new PageFollow(ids());
  for (let i = 0; i < 3; i++) page.committed(page.next());
  page.applyState(3);
  assert.equal(page.pending, false, "the Mac confirmed our PAGE_CHANGE");
  const before = page.pageId;
  // The Mac starts a fresh page for a new call (D6): index 0 again.
  assert.equal(page.applyState(0), true);
  assert.equal(page.pageIndex, 0);
  assert.notEqual(page.pageId, before);
  assert.equal(page.next().index, 1, "the next New page sends the right index");
  // A hotkey or another client moved the Mac forward.
  assert.equal(page.applyState(5), true);
  assert.equal(page.next().index, 6);
});

test("the same page_index changes nothing", () => {
  const page = new PageFollow(ids());
  const id = page.pageId;
  assert.equal(page.applyState(0), false);
  assert.equal(page.pageIndex, 0);
  assert.equal(page.pageId, id);
});

test("while our PAGE_CHANGE is pending a STATE with a lower index is stale and ignored", () => {
  const page = new PageFollow(ids());
  const next = page.next();
  page.committed(next);
  assert.equal(page.applyState(0), false, "the 1 Hz STATE emitted before the Mac handled our PAGE_CHANGE");
  assert.equal(page.applyState(0), false, "still pending: still stale");
  assert.equal(page.pageIndex, 1);
  assert.equal(page.pageId, next.id);
  assert.equal(page.applyState(1), false, "confirmed");
  assert.equal(page.pending, false);
  assert.equal(page.applyState(0), true, "now a lower index is the Mac's move and is followed");
  assert.equal(page.pageIndex, 0);
});

test("while pending, a higher index than ours is followed (the Mac moved past our request)", () => {
  const page = new PageFollow(ids());
  page.committed(page.next());
  assert.equal(page.applyState(4), true);
  assert.equal(page.pageIndex, 4);
  assert.equal(page.pending, false);
});
