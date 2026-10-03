// The toolbar: pen, highlighter, eraser, undo, redo, new page, Clear and the info button.
// Undo and redo follow the Mac's depths from STATE (the client never mutates its own undo stack on tap).

export type Tool = "pen" | "highlighter" | "eraser";

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
  tool: Tool = "pen";

  constructor(root: HTMLElement, private readonly actions: ToolbarActions) {
    const q = (id: string): HTMLButtonElement => {
      const el = root.querySelector<HTMLButtonElement>(`#${id}`);
      if (!el) throw new Error(`toolbar button #${id} missing`);
      return el;
    };
    this.toolButtons = { pen: q("tool-pen"), highlighter: q("tool-highlighter"), eraser: q("tool-eraser") };
    this.undoButton = q("undo");
    this.redoButton = q("redo");
    for (const tool of Object.keys(this.toolButtons) as Tool[]) {
      this.toolButtons[tool].addEventListener("click", () => this.select(tool));
    }
    this.undoButton.addEventListener("click", () => { if (!this.undoButton.disabled) actions.undo(); });
    this.redoButton.addEventListener("click", () => { if (!this.redoButton.disabled) actions.redo(); });
    q("new-page").addEventListener("click", () => actions.newPage());
    q("clear").addEventListener("click", () => actions.clear());
    q("info").addEventListener("click", () => actions.info());
    this.setDepths(0, 0);
    this.select("pen");
  }

  select(tool: Tool): void {
    this.tool = tool;
    for (const t of Object.keys(this.toolButtons) as Tool[]) {
      this.toolButtons[t].setAttribute("aria-pressed", t === tool ? "true" : "false");
    }
    this.actions.setTool(tool);
  }

  /** Enabled states come from STATE `undo_depth` and `redo_depth` (the Mac's truth). */
  setDepths(undoDepth: number, redoDepth: number): void {
    this.undoButton.disabled = undoDepth <= 0;
    this.redoButton.disabled = redoDepth <= 0;
  }
}
