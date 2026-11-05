import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [extDir, relayUrl, token, groupsDb, outPng] = process.argv.slice(2);
const ext = realpathSync(extDir);
const id = [...createHash("sha256").update(ext).digest("hex").slice(0, 32)].map(c => String.fromCharCode(97 + parseInt(c, 16))).join("");
const profile = mkdtempSync(join(tmpdir(), "helium-e2e-"));
const proc = spawn("/Applications/Helium.app/Contents/MacOS/Helium", [`--user-data-dir=${profile}`, "--headless=new", "--remote-debugging-port=9334", `--load-extension=${ext}`, `--disable-extensions-except=${ext}`, "--no-first-run", "--window-size=460,700", "about:blank"], { stdio: "ignore" });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let targets;
for (let i = 0; i < 40; i++) { try { targets = await (await fetch("http://127.0.0.1:9334/json")).json(); break; } catch { await sleep(250); } }
const page = targets.find(t => t.type === "page");
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
let n = 0; const pending = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); if (pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } };
const send = (method, params = {}) => new Promise(r => { const i = ++n; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async expr => { const r = (await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true, userGesture: true })).result; return r.exceptionDetails ? "EXC " + JSON.stringify(r.exceptionDetails.exception?.description) : r.result.value; };
const state = `(async()=>{const {links={}}=await chrome.storage.local.get('links');const gs=await chrome.tabGroups.query({});const out=[];for(const g of gs){const ts=await chrome.tabs.query({groupId:g.id});const tr=Object.values(links).find(l=>l.groupId===g.id)?.tracked||{};out.push(g.title+' ['+g.color+'] '+ts.length+' tabs: '+ts.map(t=>(tr[t.id]||'untracked').split('|')[1].replace('https://','')).join(', '))}return out.join(' || ')})()`;
const sql = q => execFileSync("sqlite3", [groupsDb, q]);
try {
  await send("Page.navigate", { url: `chrome-extension://${id}/options.html` }); await sleep(1500);
  await ev(`chrome.storage.local.set({relayUrl:${JSON.stringify(relayUrl)},token:${JSON.stringify(token)}}).then(()=>1)`);
  const fetchGroup = `fetch(${JSON.stringify(relayUrl + "/tabs")},{headers:{Authorization:'Bearer ${token}'}}).then(r=>r.json())`;
  console.log("1 open:", await ev(`(async()=>{const d=await ${fetchGroup};const w=await chrome.windows.getCurrent();return JSON.stringify(await chrome.runtime.sendMessage({type:'openGroup',group:d.tabGroups[0],windowId:w.id}))})()`));
  console.log("  state:", await ev(state));
  console.log("2 open again (no dupes):", await ev(`(async()=>{const d=await ${fetchGroup};return JSON.stringify(await chrome.runtime.sendMessage({type:'openGroup',group:d.tabGroups[0]}))})()`));
  console.log("  state:", await ev(state));
  // User closes "one.example" in Helium; Safari adds a tab, removes "two", renames the group.
  console.log("  user closes one.example:", await ev(`(async()=>{const {links}=await chrome.storage.local.get('links');const l=Object.values(links)[0];const id=Object.keys(l.tracked).find(k=>l.tracked[k].includes('one.example'));await chrome.tabs.remove(Number(id));return 'closed '+id})()`));
  sql("INSERT INTO bookmarks VALUES (16,10,0,0,'Third','https://three.example',4,'T-4',0,0); UPDATE bookmarks SET deleted=1 WHERE id=13; UPDATE bookmarks SET title='Design v2' WHERE id=10;");
  await sleep(1500); // the relay re-reads Safari's files on change events, after a short debounce
  console.log("3 sync:", await ev(`(async()=>{const d=await ${fetchGroup};return JSON.stringify(await chrome.runtime.sendMessage({type:'syncNow',data:d}))})()`));
  console.log("  state (expect: pin, three; no one (user closed), no two (removed); title v2):", await ev(state));
  console.log("4 user closes whole group, sync unlinks:", await ev(`(async()=>{const [g]=await chrome.tabGroups.query({});const ts=await chrome.tabs.query({groupId:g.id});await chrome.tabs.remove(ts.map(t=>t.id));const d=await ${fetchGroup};await chrome.runtime.sendMessage({type:'syncNow',data:d});const {links}=await chrome.storage.local.get('links');return 'links left: '+Object.keys(links).length})()`));
  await send("Page.addScriptToEvaluateOnNewDocument", { source: "Object.defineProperty(chrome.permissions, 'contains', {value: async () => true, configurable: true});" });
  await send("Page.navigate", { url: `chrome-extension://${id}/popup.html?page` }); await sleep(2000);
  await sleep(1500);
  console.log("popup shows group:", await ev("document.body.innerText.includes('Design v2')"));
  console.log("popup headings:", await ev("[...document.querySelectorAll('h2,h3')].map(x=>x.textContent.trim()).filter(Boolean).join(' | ')"));
  // A second load with nothing changed: the extension sends If-None-Match and the relay answers 304.
  await send("Page.navigate", { url: `chrome-extension://${id}/popup.html?page` }); await sleep(2000);
  console.log("popup after reload shows group:", await ev("document.body.innerText.includes('Design v2')"));
  const shot = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(outPng, Buffer.from(shot.result.data, "base64"));
} finally { ws.close(); proc.kill(); }
