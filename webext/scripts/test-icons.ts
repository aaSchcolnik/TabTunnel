// node --experimental-strip-types scripts/test-icons.ts
import assert from "node:assert/strict"
import { iconForGroup } from "../src/lib/icons.ts"

const name = (t: string) => (iconForGroup(t) as { displayName?: string }).displayName
const cases: [string, string][] = [
  ["Design", "Palette"], ["CSS Styles", "Paintbrush"], ["Sneakers", "Footprints"], ["Clothing", "Shirt"],
  ["Ropa en mexico", "Shirt"], ["SUITS", "Shirt"], ["Tinta Y Plumas", "Feather"], ["Learn Programming", "GraduationCap"],
  ["Angular learning", "GraduationCap"], ["ESP32", "Cpu"], ["Raspberry Pi / Self Hosting", "Server"], ["T3 Code", "SquareTerminal"],
  ["Tasky", "ListTodo"], ["Downloads", "Download"], ["Apps", "AppWindow"],
  // false positives from loose stems
  ["Open source", "Folder"], ["Links", "Folder"], ["Smart home", "House"], ["Ready", "Folder"], ["Suitcase", "Folder"],
  ["Automation", "Folder"], ["Restore", "Folder"], ["Classic", "Folder"], ["Threads", "Folder"], ["Start", "Folder"],
]
let failed = 0
for (const [title, want] of cases) {
  const got = name(title)
  if (got !== want) { failed++; console.log(`FAIL ${title}: got ${got}, want ${want}`) }
}
assert.equal(failed, 0, `${failed} icon cases failed`)
console.log(`icons: ${cases.length} cases pass`)
