import "./styles.css";
import { App } from "./app.js";

const root = document.getElementById("app")!;
new App(root);

if ("serviceWorker" in navigator && location.protocol !== "file:") {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js").catch(() => {});
  });
}
