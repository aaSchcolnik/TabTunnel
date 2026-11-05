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
manifest.host_permissions = ["http://127.0.0.1/*", "http://10.255.255.1/*"]
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
  await shot("01-popup-default.png")

  await ev(`(()=>{const t=[...document.querySelectorAll('[data-slot=collapsible-trigger]')];t.filter(b=>/Design|T3 Code/.test(b.textContent)).forEach(b=>b.click());return t.length})()`)
  await sleep(3500)
  await shot("02-popup-groups-expanded.png")
  const box = await ev(`(()=>{const r=[...document.querySelectorAll('[data-slot=collapsible-trigger]')].find(b=>/CSS Styles/.test(b.textContent)).getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()`)
  await send("Input.dispatchMouseEvent", { type: "mouseMoved", x: box[0], y: box[1] })
  await sleep(400)
  await shot("16-popup-row-hover.png")
  await send("Input.dispatchMouseEvent", { type: "mouseMoved", x: 1, y: 1 })

  await ev(`(()=>{const i=document.querySelector('input[aria-label="Search tabs"]');const set=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;set.call(i,'css');i.dispatchEvent(new Event('input',{bubbles:true}));return 1})()`)
  await sleep(2500)
  await shot("03-popup-search.png")
  // device filter: clear search, pick the iPhone chip
  await ev(`(()=>{const i=document.querySelector('input[aria-label="Search tabs"]');const set=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;set.call(i,'');i.dispatchEvent(new Event('input',{bubbles:true}));[...document.querySelectorAll('[data-slot=toggle-group-item]')].find(b=>/iPhone/.test(b.textContent)).click();return 1})()`)
  await sleep(2000)
  await shot("20-popup-filter-device.png")
  // with the iPhone filter still on, a search must still find group tabs
  await ev(`(()=>{const i=document.querySelector('input[aria-label="Search tabs"]');const set=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;set.call(i,'css');i.dispatchEvent(new Event('input',{bubbles:true}));return 1})()`)
  await sleep(1500)
  await shot("21-popup-search-with-filter.png")
  console.log("search under filter:", await ev(`document.querySelector('[role=status]')?.textContent`))
  await ev(`(()=>{const i=document.querySelector('input[aria-label="Search tabs"]');const set=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;set.call(i,'');i.dispatchEvent(new Event('input',{bubbles:true}));return 1})()`)
  await sleep(300)
  await ev(`(()=>{[...document.querySelectorAll('[data-slot=toggle-group-item]')].find(b=>/^All/.test(b.textContent.trim())).click();return 1})()`)
  await sleep(300)

  await go("popup.html", 2000)
  await ev(`document.activeElement?.blur(); 1`)
  for (let i = 0; i < 6; i++) await key("Tab", "Tab", 9)
  await sleep(400)
  await shot("04-popup-keyboard-focus.png")

  await go("popup.html", 300)
  await ev(`(async()=>{await chrome.storage.local.clear();await chrome.storage.local.set({relayUrl:'http://127.0.0.1:9',token:'x'});return 1})()`)
  await go("popup.html", 3000)
  await shot("05-popup-unreachable.png")
  console.log("focus in unreachable:", await ev("document.activeElement?.textContent || document.activeElement?.tagName"))

  await ev(`(async()=>{await chrome.storage.local.clear();return 1})()`)
  await go("popup.html", 1500)
  await shot("06-popup-not-configured.png")
  console.log("focus in not-configured:", await ev("document.activeElement?.textContent || document.activeElement?.tagName"))

  await ev(`chrome.storage.local.set({relayUrl:${JSON.stringify(relayUrl)},token:${JSON.stringify(token)}}).then(()=>1)`)
  // a linked ("Synced") group: open Design as a real tab group through the background worker
  await size(400, 600)
  await go("popup.html", 2000)
  console.log("link:", await ev(`(async()=>{const d=(await chrome.storage.local.get('cache')).cache;const g=d.tabGroups.find(x=>x.title==='Design');const w=await chrome.windows.getCurrent();return JSON.stringify(await chrome.runtime.sendMessage({type:'openGroup',group:g,windowId:w.id}))})()`))
  await send("Page.bringToFront") // openGroup activated a new tab; background pages pause animations
  await go("popup.html", 2500)
  await shot("17-popup-synced.png")
  const sb = await ev(`(()=>{const r=[...document.querySelectorAll('[data-slot=collapsible-trigger]')].find(b=>/Design/.test(b.textContent)).getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()`)
  await send("Input.dispatchMouseEvent", { type: "mouseMoved", x: sb[0], y: sb[1] })
  await sleep(400)
  await shot("19-popup-synced-hover.png")
  await send("Input.dispatchMouseEvent", { type: "mouseMoved", x: 1, y: 1 })

  await size(1280, 860)
  await go("popup.html?page", 2500)
  await ev(`(()=>{[...document.querySelectorAll('[data-slot=collapsible-trigger]')].filter(b=>/Sneakers/.test(b.textContent)).forEach(b=>b.click());return 1})()`)
  await sleep(3000)
  await shot("07-full-page.png")

  await size(400, 600)
  console.log("visible:", await ev("document.visibilityState"))
  await ev(`chrome.storage.local.remove('open').then(()=>1)`)
  await go("popup.html?preview=zen", 2500)
  await ev(`(()=>{[...document.querySelectorAll('[data-slot=collapsible-trigger]')].filter(b=>/Design/.test(b.textContent)).forEach(b=>b.click());return 1})()`)
  await sleep(2500)
  await shot("10-popup-zen-layout.png")
  const zb = await ev(`(()=>{const b=[...document.querySelectorAll('[data-slot=collapsible-trigger]')].find(b=>/Raspberry/.test(b.textContent));b.scrollIntoView({block:'center'});const r=b.getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()`)
  await send("Input.dispatchMouseEvent", { type: "mouseMoved", x: zb[0], y: zb[1] })
  await sleep(400)
  await shot("18-popup-zen-row-hover.png")
  await send("Input.dispatchMouseEvent", { type: "mouseMoved", x: 1, y: 1 })
  // collapse check: close Design again and confirm its content unmounts (animation finished)
  await ev(`(()=>{[...document.querySelectorAll('[data-slot=collapsible-trigger]')].find(b=>/Design/.test(b.textContent)).click();return 1})()`)
  await sleep(1200)
  console.log("collapse finished:", await ev(`(()=>{const t=[...document.querySelectorAll('[data-slot=collapsible-trigger]')].find(b=>/Design/.test(b.textContent));const c=t.closest('[data-slot=collapsible]').querySelector('[data-slot=collapsible-content]');return !c || c.hidden || c.getBoundingClientRect().height===0})()`))
  console.log("collapse detail:", await ev(`(()=>{const t=[...document.querySelectorAll('[data-slot=collapsible-trigger]')].find(b=>/Design/.test(b.textContent));const c=t.closest('[data-slot=collapsible]').querySelector('[data-slot=collapsible-content]');if(!c)return 'unmounted';const cs=getComputedStyle(c);return JSON.stringify({state:c.dataset.state,hidden:c.hidden,h:c.getBoundingClientRect().height,anim:cs.animationName,dur:cs.animationDuration,var:cs.getPropertyValue('--radix-collapsible-content-height'),trig:t.getAttribute('aria-expanded')})})()`))

  await go("popup.html", 2500)
  await ev(`(()=>{const v=document.querySelector('[data-slot=scroll-area-viewport]');v.scrollTop=v.scrollHeight;return 1})()`)
  await sleep(2500)
  await shot("11-popup-devices.png")

  await ev(`(()=>{const i=document.querySelector('input[aria-label="Search tabs"]');const set=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;set.call(i,'zzqx');i.dispatchEvent(new Event('input',{bubbles:true}));return 1})()`)
  await sleep(600)
  await shot("12-popup-no-match.png")

  // offline with cached data: keep the cache, point at a dead port
  await ev(`chrome.storage.local.set({relayUrl:'http://127.0.0.1:9'}).then(()=>1)`)
  await go("popup.html", 3000)
  // T3 Code was never on screen since storage was cleared: its icons come from the background prefetch
  await ev(`(()=>{[...document.querySelectorAll('[data-slot=collapsible-trigger]')].filter(b=>/T3 Code/.test(b.textContent)).forEach(b=>b.click());return 1})()`)
  await sleep(1500)
  await shot("13-popup-offline-cached.png")
  console.log("offline favicon detail:", await ev(`(async()=>{const f=(await chrome.storage.local.get('favicons')).favicons||{};const k=Object.keys(f);const out=[];for(const h of k.slice(0,4)){const u=f[h].u;const img=new Image();img.src=u;try{await img.decode();out.push(h+':'+u.length+':'+img.naturalWidth)}catch(e){out.push(h+':'+u.length+':ERR')}}return k.length+' saved; '+out.join(' | ')+' | imgs in DOM: '+document.querySelectorAll('[data-slot=avatar-image]').length})()`))
  console.log("offline favicon srcs:", await ev(`[...document.querySelectorAll('[data-slot=avatar-image]')].map(i=>i.src.slice(0,22)).join(' | ')`))

  // loading: no cache, an address that never answers
  await ev(`(async()=>{await chrome.storage.local.clear();await chrome.storage.local.set({relayUrl:'http://10.255.255.1:8787',token:'x'});return 1})()`)
  await go("popup.html", 900)
  await shot("14-popup-loading.png")

  await ev(`(async()=>{await chrome.storage.local.clear();await chrome.storage.local.set({relayUrl:${JSON.stringify(relayUrl)},token:${JSON.stringify(token)}});return 1})()`)
  await size(1280, 860)
  await go("options.html", 1500)
  await shot("08-options.png")
  await ev(`(()=>{const f=document.querySelector('form');f.requestSubmit();return 1})()`)
  await sleep(2500)
  await shot("09-options-after-save.png")
  await go("options.html?preview=zen", 1500)
  await ev(`(()=>{const i=document.getElementById('relayUrl');const set=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;set.call(i,'not a url ::');i.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('form').requestSubmit();return 1})()`)
  await sleep(800)
  await shot("15-options-invalid-zen.png")
} finally {
  ws.close()
  proc.kill()
}
