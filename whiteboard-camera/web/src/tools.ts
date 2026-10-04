// The toolbar: pen, highlighter, eraser, laser, undo, redo, new page, Clear and the info button.
// Undo and redo follow the Mac's depths from STATE (the client never mutates its own undo stack on tap).

export type Tool = "pen" | "highlighter" | "eraser" | "laser";

export interface ToolbarActions {
  setTool(tool: Tool): void;
  undo(): void;
  redo(): void;
  newPage(): void;
  clear(): void;
  info(): void;
}

export class Toolbar {
  private readonly toolButtons: Record<Tool, HTMLButtonElement>;
  private readonly undoButton: HTMLButtonElement;
  private readonly redoButton: HTMLButtonElement;
  private readonly newPageButton: HTMLButtonElement;
  private readonly clearButton: HTMLButtonElement;
  private live = false;
  private undoDepth = 0;
  private redoDepth = 0;
  tool: Tool = "pen";

  constructor(root: HTMLElement, private readonly actions: ToolbarActions) {
    const q = (id: string): HTMLButtonElement => {
      const el = root.querySelector<HTMLButtonElement>(`#${id}`);
      if (!el) throw new Error(`toolbar button #${id} missing`);
      return el;
    };
    this.toolButtons = { pen: q("tool-pen"), highlighter: q("tool-highlighter"), eraser: q("tool-eraser"), laser: q("tool-laser") };
    this.undoButton = q("undo");
    this.redoButton = q("redo");
    for (const tool of Object.keys(this.toolButtons) as Tool[]) {
      this.toolButtons[tool].addEventListener("click", () => this.select(tool));
    }
    this.newPageButton = q("new-page");
    this.clearButton = q("clear");
    this.undoButton.addEventListener("click", () => { if (!this.undoButton.disabled) actions.undo(); });
    this.redoButton.addEventListener("click", () => { if (!this.redoButton.disabled) actions.redo(); });
    this.newPageButton.addEventListener("click", () => { if (!this.newPageButton.disabled) actions.newPage(); });
    this.clearButton.addEventListener("click", () => { if (!this.clearButton.disabled) actions.clear(); });
    q("info").addEventListener("click", () => actions.info());
    this.setLive(false);
    this.select("pen");
  }

  /**
   * Clear, New page, Undo and Redo are control messages: meaningful now or never (PROTOCOL 9), and a Clear
   * replayed after a reconnect would make the Mac save a page the owner never saw. Off while not live.
   */
  setLive(live: boolean): void {
    this.live = live;
    this.newPageButton.disabled = !live;
    this.clearButton.disabled = !live;
    this.apply();
  }

  get isLive(): boolean {
    return this.live;
  }

  select(tool: Tool): void {
    this.tool = tool;
    for (const t of Object.keys(this.toolButtons) as Tool[]) {
      this.toolButtons[t].setAttribute("aria-pressed", t === tool ? "true" : "false");
    }
    this.actions.setTool(tool);
  }

  /** Enabled states come from STATE `undo_depth` and `redo_depth` (the Mac's truth), and only while live. */
  setDepths(undoDepth: number, redoDepth: number): void {
    this.undoDepth = undoDepth;
    this.redoDepth = redoDepth;
    this.apply();
  }

  private apply(): void {
    this.undoButton.disabled = !this.live || this.undoDepth <= 0;
    this.redoButton.disabled = !this.live || this.redoDepth <= 0;
  }
}
