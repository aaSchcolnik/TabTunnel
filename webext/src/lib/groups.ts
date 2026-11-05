// Mirror Safari Tab Groups into Chromium tab groups (Helium). Runs only in the background worker.
//
// A Safari group you open is "linked" to one Chromium group. Each sync is one-way, Safari -> Helium:
//   - tabs added in Safari since the last sync are added to the group;
//   - tabs removed in Safari are closed, if the extension opened them;
//   - tabs you open yourself in the group, and tabs you close, are left as you set them.
// Closing the whole group in Helium unlinks it.
import {
  api,
  fetchJson,
  getSettings,
  isWebUrl,
  type RelayData,
  type Tab,
  type TabGroup,
} from "./ext"

type Link = {
  groupId: number
  title: string
  tracked: Record<string, string>
  known: string[]
}
type Links = Record<string, Link>

const COLORS = [
  "blue",
  "red",
  "yellow",
  "green",
  "pink",
  "purple",
  "cyan",
  "orange",
  "grey",
] as const

export function colorFor(title: string): chrome.tabGroups.Color {
  let h = 0
  for (const ch of title) h = (h * 31 + ch.codePointAt(0)!) >>> 0
  return COLORS[h % COLORS.length] as chrome.tabGroups.Color
}

const keyOf = (t: Tab) => `${t.id || ""}|${t.url}`
const openable = (t: Tab) => isWebUrl(t.url) // never javascript:, data:, file: … from synced data

async function getLinks(): Promise<Links> {
  const { links = {} } = await api.storage.local.get("links")
  return links as Links
}

const setLinks = (links: Links) => api.storage.local.set({ links })

async function groupExists(groupId: number) {
  try {
    await api.tabGroups.get(groupId)
    return true
  } catch {
    return false
  }
}

/** Open a Safari group as a new Helium tab group, or focus and resync it if it's already linked. */
export async function openGroup(group: TabGroup, windowId?: number) {
  const links = await getLinks()
  const link = links[group.id]
  if (link && (await groupExists(link.groupId))) {
    await syncOne(group, link)
    links[group.id] = link
    await setLinks(links)
    const [first] = await api.tabs.query({ groupId: link.groupId })
    if (first?.id != null) {
      await api.tabs.update(first.id, { active: true })
      await api.windows.update(first.windowId, { focused: true })
    }
    await api.tabGroups.update(link.groupId, { collapsed: false })
    return { created: false, groupId: link.groupId }
  }

  const tabs = group.tabs.filter(openable)
  if (!tabs.length) throw new Error("This group has no tabs Helium can open.")
  const tracked: Record<string, string> = {}
  const ids: number[] = []
  for (const [i, t] of tabs.entries()) {
    const tab = await api.tabs.create({ url: t.url, active: i === 0, windowId })
    tracked[tab.id!] = keyOf(t)
    ids.push(tab.id!)
  }
  const groupId = await api.tabs.group({
    tabIds: ids as [number, ...number[]],
    createProperties: windowId ? { windowId } : undefined,
  })
  await api.tabGroups.update(groupId, {
    title: group.title,
    color: colorFor(group.title),
  })
  links[group.id] = {
    groupId,
    title: group.title,
    tracked,
    known: tabs.map(keyOf),
  }
  await setLinks(links)
  return { created: true, groupId }
}

async function syncOne(group: TabGroup, link: Link) {
  const desired = group.tabs.filter(openable)
  const desiredKeys = new Set(desired.map(keyOf))
  const known = new Set(link.known || [])
  const liveTabs = await api.tabs.query({ groupId: link.groupId })
  const liveIds = new Set(liveTabs.map((t) => t.id))

  for (const id of Object.keys(link.tracked)) {
    if (!liveIds.has(Number(id))) delete link.tracked[id] // closed or dragged out by the user
  }

  const toClose = Object.entries(link.tracked)
    .filter(([, key]) => !desiredKeys.has(key))
    .map(([id]) => Number(id))
  if (toClose.length) {
    await api.tabs.remove(toClose)
    for (const id of toClose) delete link.tracked[id]
  }

  const toAdd = desired.filter((t) => !known.has(keyOf(t)))
  if (toAdd.length) {
    const windowId = liveTabs[0]?.windowId
    const ids: number[] = []
    for (const t of toAdd) {
      const tab = await api.tabs.create({ url: t.url, active: false, windowId })
      link.tracked[tab.id!] = keyOf(t)
      ids.push(tab.id!)
    }
    await api.tabs.group({
      groupId: link.groupId,
      tabIds: ids as [number, ...number[]],
    })
  }

  if (link.title !== group.title) {
    await api.tabGroups.update(link.groupId, { title: group.title })
    link.title = group.title
  }
  link.known = [...desiredKeys]
}

/** Bring every linked group up to date (background alarm, and whenever the popup loads data). */
export async function syncLinked(data?: RelayData) {
  const links = await getLinks()
  if (!Object.keys(links).length) return
  if (!data) {
    const { relayUrl, token } = await getSettings()
    if (!relayUrl) return
    data = await fetchJson(relayUrl, token)
  }
  const byId = new Map((data.tabGroups || []).map((g) => [g.id, g]))
  for (const [safariId, link] of Object.entries(links)) {
    if (!(await groupExists(link.groupId))) {
      delete links[safariId]
      continue
    }
    const group = byId.get(safariId)
    if (!group) continue // deleted in Safari: leave the Helium group alone
    try {
      await syncOne(group, link)
    } catch (e) {
      console.warn("sync failed for", link.title, e)
    }
  }
  await setLinks(links)
}

export async function linkedGroupIds(): Promise<Set<string>> {
  if (!api.tabGroups) return new Set()
  const links = await getLinks()
  const out = new Set<string>()
  for (const [safariId, link] of Object.entries(links)) {
    if (await groupExists(link.groupId)) out.add(safariId)
  }
  return out
}
