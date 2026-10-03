// Offline ring: SolStream frames drawn while the socket is down (or still pending Allow) wait here
// and are replayed in order when the connection becomes live. Bounded by points, not frames, so a
// Wi-Fi blip never loses a sentence and a long outage drops the OLDEST whole strokes first.
// No DOM dependency: the Node unit test imports this file.

export const RING_CAPACITY_POINTS = 2000;

export interface RingEntry {
  /** The encoded SolStream frame, ready for `WebSocket.send`. */
  frame: ArrayBuffer;
  /** Stroke id (hex) the frame belongs to; "" for stroke-independent frames (erase, page change). */
  strokeKey: string;
  /** Points carried by this frame (chunks only; everything else counts 0). */
  points: number;
}

export class Ring {
  private entries: RingEntry[] = [];
  private pointTotal = 0;
  /** Whole strokes dropped because the ring was full (diagnostics). */
  droppedStrokes = 0;

  constructor(readonly capacityPoints: number = RING_CAPACITY_POINTS) {}

  get length(): number {
    return this.entries.length;
  }

  get points(): number {
    return this.pointTotal;
  }

  /** Queues a frame. When the point budget overflows, the oldest stroke (all of its frames) is dropped. */
  push(frame: ArrayBuffer, strokeKey: string, points = 0): void {
    this.entries.push({ frame, strokeKey, points });
    this.pointTotal += points;
    while (this.pointTotal > this.capacityPoints && this.entries.length > 0) {
      const victim = this.oldestStrokeKey();
      if (victim === null) break;
      this.dropStroke(victim);
    }
  }

  /** Removes and returns everything in arrival order. */
  drain(): ArrayBuffer[] {
    const out = this.entries.map((e) => e.frame);
    this.entries = [];
    this.pointTotal = 0;
    return out;
  }

  clear(): void {
    this.entries = [];
    this.pointTotal = 0;
  }

  private oldestStrokeKey(): string | null {
    // The oldest stroke that actually carries points; a frame with key "" (erase, page change) is
    // dropped on its own when it is the oldest thing left.
    for (const e of this.entries) {
      if (e.points > 0 || e.strokeKey !== "") return e.strokeKey;
    }
    const first = this.entries[0];
    return first ? first.strokeKey : null;
  }

  private dropStroke(key: string): void {
    if (key === "") {
      const first = this.entries.shift();
      if (first) this.pointTotal -= first.points;
      return;
    }
    const kept: RingEntry[] = [];
    for (const e of this.entries) {
      if (e.strokeKey === key) this.pointTotal -= e.points;
      else kept.push(e);
    }
    this.entries = kept;
    this.droppedStrokes++;
  }
}
