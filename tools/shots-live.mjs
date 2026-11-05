// Screenshot every extension state for design review.
// Usage: node tools/shots.mjs <dist/chromium> <relayUrl> <token> <outDir>
// Copies the build, grants the relay host up front (headless can't click the permission prompt),
// loads it into a throwaway headless Helium and captures each view at 2x.
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { cpSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync, realpathSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const [distDir, relayUrl, token, outDir] = process.argv.slice(2)
mkdirSync(outDir, { recursive: true })
const ext = join(mkdtempSync(join(tmpdir(), "ext-shots-")), "ext")
cpSync(distDir, ext, { recursive: true })
const manifest = JSON.parse(readFileSync(join(ext, "manifest.json"), "utf8"))
manifest.host_permissions = [`${new URL(relayUrl).protocol}//${new URL(relayUrl).hostname}/*`]
writeFileSync(join(ext, "manifest.json"), JSON.stringify(manifest))
const real = realpathSync(ext)
const id = [...createHash("sha256").update(real).digest("hex").slice(0, 32)].map((c) => String.fromCharCode(97 + parseInt(c, 16))).join("")

const profile = mkdtempSync(join(tmpdir(), "helium-shots-"))
const proc = spawn("/Applications/Helium.app/Contents/MacOS/Helium", [
  `--user-data-dir=${profile}`, "--headless=new", "--remote-debugging-port=9335", `--load-extension=${real}`,
  `--disable-extensions-except=${real}`, "--no-first-run", "--force-dark-mode", "about:blank",
], { stdio: "ignore" })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let targets
for (let i = 0; i < 40; i++) { try { targets = await (await fetch("http://127.0.0.1:9335/json")).json(); break } catch { await sleep(250) } }
const ws = new WebSocket(targets.find((t) => t.type === "page").webSocketDebuggerUrl)
await new Promise((r) => (ws.onopen = r))
let n = 0
const pending = new Map()
ws.onmessage = (e) => { const m = JSON.parse(e.data); pending.get(m.id)?.(m); pending.delete(m.id) }
const send = (method, params = {}) => new Promise((r) => { const i = ++n; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })) })
const ev = async (expr) => {
  const r = (await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true, userGesture: true })).result
  return r.exceptionDetails ? "EXC " + (r.exceptionDetails.exception?.description || r.exceptionDetails.text) : r.result?.value
}
const size = (width, height) => send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 2, mobile: false })
const go = async (path, wait = 1800) => { await send("Page.navigate", { url: `chrome-extension://${id}/${path}` }); await sleep(wait) }
const shot = async (name) => {
  const r = await send("Page.captureScreenshot", { format: "png" })
  writeFileSync(join(outDir, name), Buffer.from(r.result.data, "base64"))
  console.log("wrote", name)
}
const key = (k, code, vk, mods = 0) => Promise.all(["keyDown", "keyUp"].map((type) =>
  send("Input.dispatchKeyEvent", { type, key: k, code, windowsVirtualKeyCode: vk, modifiers: mods })))

try {
  await send("Page.enable")
  await go("options.html", 800)
  await ev(`chrome.storage.local.clear().then(()=>chrome.storage.local.set({relayUrl:${JSON.stringify(relayUrl)},token:${JSON.stringify(token)}})).then(()=>1)`)

  await size(400, 600)
  await go("popup.html", 2500)
  await sleep(1500)
  await shot("live-popup.png")
  await ev(`(()=>{[...document.querySelectorAll('[data-slot=collapsible-trigger]')].filter(b=>/Design|Sneakers/.test(b.textContent)).forEach(b=>b.click());return 1})()`)
  await sleep(4000)
  await shot("live-popup-expanded.png")
} finally {
  ws.close()
  proc.kill()
}
