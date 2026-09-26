type Child = Node | string | number | null | undefined | false | Child[];

/** Tiny DOM builder: h("button.btn.primary", { onclick }, "Save") */
export function h(sel: string, attrs: Record<string, unknown> | null = null, ...children: Child[]): HTMLElement {
  const [tag, ...classes] = sel.split(".");
  const el = document.createElement(tag || "div");
  if (classes.length) el.className = classes.join(" ");
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v === null || v === undefined || v === false) continue;
      if (k.startsWith("on") && typeof v === "function") (el as unknown as Record<string, unknown>)[k] = v;
      else if (k === "style" && typeof v === "object") Object.assign(el.style, v);
      else if (k === "dataset" && typeof v === "object") Object.assign(el.dataset, v);
      else if (k in el && k !== "list") (el as unknown as Record<string, unknown>)[k] = v;
      else el.setAttribute(k, String(v));
    }
  }
  append(el, children);
  return el;
}

function append(el: HTMLElement, children: Child[]) {
  for (const c of children) {
    if (c === null || c === undefined || c === false) continue;
    if (Array.isArray(c)) append(el, c);
    else if (c instanceof Node) el.appendChild(c);
    else el.appendChild(document.createTextNode(String(c)));
  }
}

/** Append children, skipping null/false like h() does. */
export function put(el: HTMLElement, ...children: Child[]) {
  append(el, children);
}

export function clear(el: HTMLElement) {
  while (el.firstChild) el.removeChild(el.firstChild);
}

export function fmtCountdown(ms: number): string {
  const s = Math.max(0, Math.ceil(ms / 1000));
  const m = Math.floor(s / 60);
  return `${m}:${String(s % 60).padStart(2, "0")}`;
}

export function fmtElapsed(ms: number): string {
  const m = Math.max(0, Math.floor(ms / 60_000));
  const hrs = Math.floor(m / 60);
  return hrs ? `${hrs}h ${String(m % 60).padStart(2, "0")}m` : `${m}m`;
}

export function fmtTime(isoOrMs: string | number): string {
  const d = new Date(isoOrMs);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

export function fmtDate(iso: string): string {
  return new Date(iso).toLocaleDateString([], { weekday: "short", month: "short", day: "numeric" });
}

let toastTimer: number | null = null;
export function toast(text: string, ms = 3500) {
  document.querySelector(".toast")?.remove();
  const el = h("div.toast", { role: "status" }, text);
  document.body.appendChild(el);
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => el.remove(), ms);
}
