// Favicons, kept in extension storage so they also show when the Mac is off.
//
// Icons are fetched from the relay with the token in an Authorization header, never in a URL (so it
// never lands in the browser's cache index or history). Rows render only these stored copies: 32px
// PNG data URLs, ~1-3 KB per site, refreshed weekly and pruned after 60 days unused.
import {
  api,
  CAN_GROUP,
  clientHeaders,
  faviconEndpoint,
  hostOf,
  type Settings,
} from "./ext"

type Entry = { u: string; t: number }
const KEY = "favicons"
const REFRESH_MS = 7 * 24 * 3600 * 1000
const PRUNE_MS = 60 * 24 * 3600 * 1000

let store: Record<string, Entry> = {}
let loaded: Promise<void> | null = null
let pending: Record<string, Entry> = {}
let flushTimer: ReturnType<typeof setTimeout> | undefined
const listeners = new Set<() => void>()
// sites the relay had no icon for (this session): Helium falls back to its own favicon cache for these
const misses = new Set<string>()

/** Load the store once; call before rendering rows so saved icons paint on the first frame. */
export function loadFavicons(): Promise<void> {
  loaded ??= api.storage.local.get(KEY).then((r) => {
    store = (r[KEY] as Record<string, Entry>) || {}
  })
  return loaded
}

/** Re-render when new icons arrive. Returns an unsubscribe function. */
export function onFaviconsChanged(cb: () => void): () => void {
  listeners.add(cb)
  return () => {
    listeners.delete(cb)
  }
}

/**
 * The icon for a page: the stored copy; else, in Helium, the browser's own favicon cache (local, no
 * network) for sites the relay had nothing for; else undefined (the row shows a letter tile).
 */
export function faviconFor(pageUrl: string): string | undefined {
  const host = hostOf(pageUrl)
  const saved = store[host]?.u
  if (saved) return saved
  if (CAN_GROUP && misses.has(host) && /^https?:/i.test(pageUrl)) {
    const u = new URL(api.runtime.getURL("/_favicon/"))
    u.searchParams.set("pageUrl", pageUrl)
    u.searchParams.set("size", "32")
    return u.toString()
  }
  return undefined
}

export async function clearFavicons() {
  store = {}
  pending = {}
  await api.storage.local.remove(KEY)
  listeners.forEach((cb) => cb())
}

function flush() {
  flushTimer = undefined
  const batch = pending
  pending = {}
  api.storage.local
    .get(KEY)
    .then((r) => {
      const cutoff = Date.now() - PRUNE_MS
      const merged = { ...((r[KEY] as Record<string, Entry>) || {}), ...batch }
      for (const [host, e] of Object.entries(merged))
        if (e.t < cutoff) delete merged[host]
      return api.storage.local.set({ [KEY]: merged })
    })
    .catch(() => {})
  listeners.forEach((cb) => cb())
}

async function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader()
    r.onload = () => resolve(r.result as string)
    r.onerror = () => reject(r.error)
    r.readAsDataURL(blob)
  })
}

/** Always re-encode to a 32px PNG: no SVG (or anything else) is stored or rendered as-is. */
async function toEntry(blob: Blob): Promise<Entry | null> {
  try {
    const bmp = await createImageBitmap(blob, {
      resizeWidth: 32,
      resizeHeight: 32,
      resizeQuality: "high",
    })
    const canvas = new OffscreenCanvas(32, 32)
    canvas.getContext("2d")!.drawImage(bmp, 0, 0)
    return {
      u: await blobToDataUrl(await canvas.convertToBlob({ type: "image/png" })),
      t: Date.now(),
    }
  } catch {
    // createImageBitmap can't decode SVG off-screen: rasterize it through an <img> instead.
    if (
      blob.type !== "image/svg+xml" ||
      typeof document === "undefined" ||
      blob.size > 100_000
    )
      return null
    const url = URL.createObjectURL(blob)
    try {
      const img = new Image(32, 32)
      img.src = url
      await img.decode()
      const canvas = document.createElement("canvas")
      canvas.width = canvas.height = 32
      canvas.getContext("2d")!.drawImage(img, 0, 0, 32, 32)
      return { u: canvas.toDataURL("image/png"), t: Date.now() }
    } catch {
      return null
    } finally {
      URL.revokeObjectURL(url)
    }
  }
}

/**
 * After a successful load, fetch and store icons for every site that has none yet (or a week-old one),
 * 6 at a time. A failed refresh keeps the old copy.
 */
export async function prefetchFavicons(settings: Settings, pageUrls: string[]) {
  await loadFavicons()
  if (!settings.relayUrl || !settings.token) return
  const todo = new Map<string, string>()
  for (const u of pageUrls) {
    const host = hostOf(u)
    const saved = store[host]
    if (
      host &&
      !todo.has(host) &&
      /^https?:/i.test(u) &&
      (!saved || Date.now() - saved.t > REFRESH_MS)
    )
      todo.set(host, u)
  }
  const queue = [...todo.entries()]
  const worker = async () => {
    for (let next = queue.shift(); next; next = queue.shift()) {
      const [host, url] = next
      try {
        const res = await fetch(faviconEndpoint(settings, url), {
          headers: {
            ...clientHeaders(),
            Authorization: `Bearer ${settings.token}`,
          },
          cache: "no-store",
          credentials: "omit",
        })
        if (!res.ok) {
          if (res.status === 404 && !store[host]) {
            misses.add(host)
            listeners.forEach((cb) => cb())
          }
          continue
        }
        const entry = await toEntry(await res.blob())
        if (!entry) continue
        store[host] = entry
        pending[host] = entry
        flushTimer ??= setTimeout(flush, 500)
      } catch {
        /* offline or decode error: try again next time */
      }
    }
  }
  await Promise.all(Array.from({ length: 6 }, worker))
}
