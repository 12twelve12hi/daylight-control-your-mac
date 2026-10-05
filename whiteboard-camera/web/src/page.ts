/**
 * The page this tablet draws on: its id and index (PROTOCOL PAGE_CHANGE), following STATE `page_index` the way
 * Daylight Ink does (`StrokeSession.applyState`): when the Mac reports another page (a hotkey, another client, or a
 * fresh page for a new call, which goes back to index 0) the local index takes the Mac's value and the page gets a
 * new id, so the next New page sends the right index. A STATE emitted before the Mac handled our own PAGE_CHANGE
 * still carries the old, lower index: while a PAGE_CHANGE is pending such a STATE is ignored.
 */
export class PageFollow {
  pageId: Uint8Array;
  pageIndex = 0;
  /** A PAGE_CHANGE was sent and no STATE has confirmed it yet. */
  pending = false;

  constructor(private readonly newId: () => Uint8Array) {
    this.pageId = newId();
  }

  /** The id and index a New page sends; nothing changes until `committed` (a refused control is dropped). */
  next(): { id: Uint8Array; index: number } {
    return { id: this.newId(), index: this.pageIndex + 1 };
  }

  /** The PAGE_CHANGE from `next()` was sent. */
  committed(page: { id: Uint8Array; index: number }): void {
    this.pageId = page.id;
    this.pageIndex = page.index;
    this.pending = true;
  }

  /** STATE arrived with the Mac's `page_index`; returns true when the local page followed it. */
  applyState(macIndex: number): boolean {
    if (macIndex === this.pageIndex) {
      this.pending = false;
      return false;
    }
    if (this.pending && macIndex < this.pageIndex) return false;   // stale: the Mac has not seen our PAGE_CHANGE yet
    this.pageIndex = macIndex;
    this.pageId = this.newId();
    this.pending = false;
    return true;
  }
}
