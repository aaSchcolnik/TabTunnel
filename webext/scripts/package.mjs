// Turn build/ into dist/chromium and dist/firefox (+ zips). Zen gets no background worker:
// tab-group mirroring is Chromium-only; Zen uses RSS Live Folders from the relay instead.
import { cpSync, mkdirSync, rmSync, copyFileSync, existsSync } from "node:fs"
import { execFileSync } from "node:child_process"

rmSync("dist", { recursive: true, force: true })
for (const target of ["chromium", "firefox"]) {
  const out = `dist/${target}`
  mkdirSync(out, { recursive: true })
  cpSync("build", out, { recursive: true })
  cpSync("icons", `${out}/icons`, { recursive: true })
  copyFileSync(`manifests/${target}.json`, `${out}/manifest.json`)
  if (target === "firefox" && existsSync(`${out}/background.js`)) rmSync(`${out}/background.js`)
  execFileSync("zip", ["-qr", "-X", `../icloud-tabs-relay-${target}.zip`, "."], { cwd: out })
}
console.log("dist/chromium, dist/firefox and zips written")
