// Browser + relay plumbing shared by the popup, options page and background worker.
// Chromium exposes `chrome`, Firefox/Zen expose `browser`; both are promise-based under MV3.

/* eslint-disable @typescript-eslint/no-explicit-any */
export const api: typeof chrome =
  (globalThis as any).browser ?? (globalThis as any).chrome

// `?preview=zen` renders the Zen layout in Chromium, for screenshots only.
const PREVIEW_ZEN =
  typeof location !== "undefined" &&
  new URLSearchParams(location.search).get("preview") === "zen"
export const IS_GECKO =
  api.runtime.getURL("").startsWith("moz-extension:") || PREVIEW_ZEN
/** Chromium can mirror Safari groups into real tab groups; Zen can't make folders from an extension. */
export const CAN_GROUP = !IS_GECKO && !!api.tabGroups

export function clientHeaders(): Record<string, string> {
  return {
    "X-TabTunnel-Client": `${IS_GECKO ? "firefox" : "chromium"}/${api.runtime.getManifest().version}`,
  }
}

export type Tab = { id?: string; title: string; url: string; pinned?: boolean }
export type DeviceKind = "phone" | "tablet" | "laptop" | "desktop" | "unknown"
export type Device = {
  name: string
  kind?: DeviceKind
  lastModified?: string | null
  tabs: Tab[]
}
export type TabGroup = { id: string; title: string; tabs: Tab[] }
export type RelayData = {
  updatedAt: string
  sourceModifiedAt?: string
  devices: Device[]
  tabGroups?: TabGroup[]
  stale?: boolean
  error?: string
}
export type Settings = { relayUrl: string; token: string }

type TabsValidator = {
  relayUrl: string
  fingerprint: string
  etag: string
  data?: RelayData | null
}

async function tokenFingerprint(token: string): Promise<string> {
  const hash = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(token)
  )
  return Array.from(new Uint8Array(hash), (byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("")
}

export async function getSettings(): Promise<Settings> {
  const { relayUrl = "", token = "" } = await api.storage.local.get([
    "relayUrl",
    "token",
  ])
  return { relayUrl: relayUrl as string, token: token as string }
}

export function normalizeUrl(raw: string): string {
  let s = raw.trim()
  if (!s) return ""
  if (!/^https?:\/\//i.test(s)) s = "http://" + s
  return new URL(s).origin
}

export function originPattern(relayUrl: string): string {
  const u = new URL(relayUrl)
  return `${u.protocol}//${u.hostname}/*`
}

export async function hasHostPermission(relayUrl: string): Promise<boolean> {
  try {
    return await api.permissions.contains({
      origins: [originPattern(relayUrl)],
    })
  } catch {
    return false
  }
}

export async function fetchJson(
  relayUrl: string,
  token: string,
  path = "/tabs",
  timeoutMs = 8000
): Promise<RelayData> {
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), timeoutMs)
  try {
    const fingerprint = path === "/tabs" ? await tokenFingerprint(token) : ""
    const saved =
      path === "/tabs"
        ? ((await api.storage.local.get("tabsValidator")).tabsValidator as
            TabsValidator | undefined)
        : undefined
    const validator =
      saved?.relayUrl === relayUrl && saved?.fingerprint === fingerprint
        ? saved
        : undefined
    const headers = {
      ...clientHeaders(),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    }
    const request = (conditional: boolean) =>
      fetch(relayUrl + path, {
        headers: {
          ...headers,
          ...(conditional && validator?.etag
            ? { "If-None-Match": validator.etag }
            : {}),
        },
        cache: "no-store",
        credentials: "omit",
        signal: ctrl.signal,
      })
    let res = await request(true)
    if (res.status === 304 && path === "/tabs") {
      if (validator?.data != null) return validator.data
      res = await request(false)
    }
    let body: any = null
    try {
      body = await res.json()
    } catch {
      /* non-JSON error page */
    }
    if (!res.ok) {
      throw new Error(
        res.status === 401
          ? "The relay rejected the token. Check it in Settings."
          : body?.error || `HTTP ${res.status}`
      )
    }
    if (path === "/tabs" && res.status === 200) {
      const etag = res.headers.get("ETag")
      if (etag) {
        await api.storage.local.set({
          tabsValidator: { relayUrl, fingerprint, etag, data: body },
        })
      } else {
        await api.storage.local.remove("tabsValidator")
      }
    }
    return body as RelayData
  } catch (e: any) {
    if (e?.name === "AbortError")
      throw new Error(
        "The relay didn't answer in time. Is the Mac awake and on Tailscale?",
        { cause: e }
      )
    if (e instanceof TypeError)
      throw new Error(
        "Couldn't reach the relay. Is the Mac awake and on Tailscale?",
        { cause: e }
      )
    throw e
  } finally {
    clearTimeout(timer)
  }
}

/** Relay favicon endpoint for a page. The token goes in an Authorization header, never in this URL. */
export function faviconEndpoint(settings: Settings, pageUrl: string): string {
  const u = new URL("/favicon", settings.relayUrl)
  u.searchParams.set("url", pageUrl)
  return u.toString()
}

/**
 * Ask the relay for this group's Zen feed address. It carries a per-group key that can read only that
 * one feed, so the master token never goes into Zen, the clipboard or a URL.
 */
export async function feedLink(
  settings: Settings,
  group: TabGroup
): Promise<string> {
  const res = await fetch(
    new URL(`/feeds/${encodeURIComponent(group.id)}/link`, settings.relayUrl),
    {
      headers: {
        ...clientHeaders(),
        Authorization: `Bearer ${settings.token}`,
      },
      cache: "no-store",
      credentials: "omit",
    }
  )
  const body = await res.json().catch(() => null)
  if (!res.ok || !body?.url)
    throw new Error(body?.error || `HTTP ${res.status}`)
  return body.url as string
}

/** Only web pages open from synced data; anything else (javascript:, data:, file:, ...) is ignored. */
export function isWebUrl(url: string): boolean {
  try {
    const p = new URL(url).protocol
    return p === "https:" || p === "http:"
  } catch {
    return false
  }
}

/** Forget everything synced: tab snapshot, open/filter state, linked groups, stored favicons. */
export async function clearSavedData() {
  await api.storage.local.remove([
    "cache",
    "open",
    "view",
    "links",
    "favicons",
    "tabsValidator",
  ])
}

export function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "")
  } catch {
    return url
  }
}

export function timeAgo(iso?: string | null): string {
  if (!iso) return ""
  const s = Math.round((Date.now() - Date.parse(iso)) / 1000)
  if (s < 45) return "just now"
  const m = Math.round(s / 60)
  if (m < 60) return `${m} min ago`
  const h = Math.round(m / 60)
  if (h < 36) return `${h} h ago`
  return `${Math.round(h / 24)} d ago`
}
