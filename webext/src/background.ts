// Chromium only. All tab-group work runs here, one job at a time: the popup closes as soon as a
// tab is activated (which would cut an open-group loop short), and the queue keeps the 2-minute
// sync from racing a manual "Open".
import { api, type RelayData, type TabGroup } from "./lib/ext"
import { openGroup, syncLinked } from "./lib/groups"

const ALARM = "sync-tab-groups"
let queue: Promise<unknown> = Promise.resolve()
function enqueue<T>(job: () => Promise<T>): Promise<T> {
  const next = queue.then(job, job)
  queue = next.catch(() => {})
  return next
}

const ensureAlarm = () => api.alarms.create(ALARM, { periodInMinutes: 2 })
api.runtime.onInstalled.addListener(ensureAlarm)
api.runtime.onStartup.addListener(ensureAlarm)

api.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name !== ALARM) return
  enqueue(() => syncLinked()).catch((e) =>
    console.warn("tab group sync skipped:", e?.message)
  )
})

type Msg =
  | { type: "openGroup"; group: TabGroup; windowId?: number }
  | { type: "syncNow"; data?: RelayData }

api.runtime.onMessage.addListener((msg: Msg, sender, sendResponse) => {
  // Only this extension's own pages (popup, options) may drive tab groups. There are no content
  // scripts and no externally_connectable, so this is defense in depth.
  if (sender.id !== api.runtime.id || !sender.url?.startsWith(api.runtime.getURL(""))) return false
  if (msg?.type === "openGroup") {
    enqueue(() => openGroup(msg.group, msg.windowId)).then(
      (r) => sendResponse({ ok: true, ...r }),
      (e) => sendResponse({ ok: false, error: e?.message })
    )
    return true
  }
  if (msg?.type === "syncNow") {
    enqueue(() => syncLinked(msg.data)).then(
      () => sendResponse({ ok: true }),
      (e) => sendResponse({ ok: false, error: e?.message })
    )
    return true
  }
  return false
})
