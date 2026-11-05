import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react"
import {
  ChevronRightIcon,
  ClockAlertIcon,
  ExternalLinkIcon,
  FolderSymlinkIcon,
  Maximize2Icon,
  PinIcon,
  PlugIcon,
  RefreshCwIcon,
  RssIcon,
  SearchIcon,
  SettingsIcon,
  ShieldAlertIcon,
  WifiOffIcon,
  XIcon,
  type LucideIcon,
} from "lucide-react"
import { toast } from "sonner"

import {
  Alert,
  AlertAction,
  AlertDescription,
  AlertTitle,
} from "@/components/ui/alert"
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from "@/components/ui/collapsible"
import {
  Empty,
  EmptyContent,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
} from "@/components/ui/empty"
import {
  InputGroup,
  InputGroupAddon,
  InputGroupButton,
  InputGroupInput,
} from "@/components/ui/input-group"
import { Kbd } from "@/components/ui/kbd"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Skeleton } from "@/components/ui/skeleton"
import { Spinner } from "@/components/ui/spinner"
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip"
import {
  api,
  CAN_GROUP,
  feedLink,
  isWebUrl,
  fetchJson,
  getSettings,
  hasHostPermission,
  hostOf,
  timeAgo,
  type RelayData,
  type Settings,
  type Tab,
  type TabGroup,
} from "@/lib/ext"
import { linkedGroupIds } from "@/lib/groups"
import {
  faviconFor,
  loadFavicons,
  onFaviconsChanged,
  prefetchFavicons,
} from "@/lib/favicons"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import { iconForDevice, iconForGroup } from "@/lib/icons"
import { FoldersIcon } from "lucide-react"
import { cn } from "@/lib/utils"

const IS_PAGE = new URLSearchParams(location.search).has("page")

type Problem = {
  kind: "setup" | "access" | "error" | "stale"
  title: string
  detail: string
} | null

const tabKey = (t: Tab) => (t.id || "") + t.url

export function Popup() {
  const [settings, setSettings] = useState<Settings>({
    relayUrl: "",
    token: "",
  })
  const [data, setData] = useState<RelayData | null>(null)
  const [loading, setLoading] = useState(true)
  const [problem, setProblem] = useState<Problem>(null)
  const [query, setQuery] = useState("")
  const [open, setOpen] = useState<Record<string, boolean>>({})
  const [linked, setLinked] = useState<Set<string>>(new Set())
  // "all" | "groups" | "d:<device name>": which tabs the list shows
  const [view, setView] = useState("all")
  const [, setIconVersion] = useState(0)
  useEffect(() => onFaviconsChanged(() => setIconVersion((v) => v + 1)), [])
  const searchRef = useRef<HTMLInputElement>(null)

  const load = useCallback(async () => {
    setLoading(true)
    const s = await getSettings()
    setSettings(s)
    try {
      if (!s.relayUrl) {
        setProblem({
          kind: "setup",
          title: "Connect to your Mac",
          detail:
            "Add the relay address and token in Settings to see your Safari tabs.",
        })
        return
      }
      if (!(await hasHostPermission(s.relayUrl))) {
        setProblem({
          kind: "access",
          title: "Allow access to the relay",
          detail:
            "Open Settings and press Save and test to let the browser reach your Mac.",
        })
        return
      }
      const fresh = await fetchJson(s.relayUrl, s.token)
      setData(fresh)
      await api.storage.local.set({ cache: fresh })
      // keep icons for every tab, so the list still has them when the Mac is off
      prefetchFavicons(s, [
        ...(fresh.tabGroups || []).flatMap((g) => g.tabs.map((t) => t.url)),
        ...fresh.devices.flatMap((d) => d.tabs.map((t) => t.url)),
      ]).catch(() => {})
      setProblem(
        fresh.stale
          ? {
              kind: "stale",
              title: "Showing older tabs",
              detail: fresh.error || "The relay couldn't read Safari.",
            }
          : null
      )
      if (CAN_GROUP) {
        setLinked(await linkedGroupIds())
        api.runtime
          .sendMessage({ type: "syncNow", data: fresh })
          .catch(() => {})
      }
    } catch (e) {
      setProblem({
        kind: "error",
        title: "Can't reach your Mac",
        detail: (e as Error).message,
      })
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    ;(async () => {
      const [stored] = await Promise.all([
        api.storage.local.get(["cache", "open", "view"]),
        loadFavicons(),
      ])
      if (stored.view) setView(stored.view as string)
      if (stored.cache) setData(stored.cache as RelayData)
      if (stored.open) setOpen(stored.open as Record<string, boolean>)
      setSettings(await getSettings())
      if (CAN_GROUP) setLinked(await linkedGroupIds())
      load()
    })()
  }, [load])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "/" && document.activeElement !== searchRef.current) {
        e.preventDefault()
        searchRef.current?.focus()
      }
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [])

  const toggle = (key: string, value: boolean) => {
    setOpen((prev) => {
      const next = { ...prev, [key]: value }
      api.storage.local.set({ open: next })
      return next
    })
  }

  const q = query.trim().toLowerCase()
  const match = useCallback(
    (t: Tab) =>
      !q ||
      t.title.toLowerCase().includes(q) ||
      t.url.toLowerCase().includes(q),
    [q]
  )

  // A saved filter whose target is gone (device renamed or signed out, all groups deleted) falls back to "all".
  const chosenView =
    (view.startsWith("d:") &&
      !(data?.devices || []).some((d) => `d:${d.name}` === view)) ||
    (view === "groups" && data && !(data.tabGroups || []).length)
      ? "all"
      : view
  // Searching always covers every tab, so a filter left on from last time can't hide a match.
  const activeView = query.trim() ? "all" : chosenView
  const chooseView = (v: string) => {
    if (!v) return // ToggleGroup sends "" when the pressed chip is clicked again
    setView(v)
    api.storage.local.set({ view: v })
  }

  const groups = useMemo(
    () =>
      (activeView === "all" || activeView === "groups"
        ? data?.tabGroups || []
        : []
      )
        .map((g) => ({
          ...g,
          shown:
            q && g.title.toLowerCase().includes(q)
              ? g.tabs
              : g.tabs.filter(match),
        }))
        .filter((g) => g.shown.length),
    [data, q, match, activeView]
  )
  const devices = useMemo(
    () =>
      (data?.devices || [])
        .filter((d) => activeView === "all" || activeView === `d:${d.name}`)
        .map((d) => ({ ...d, shown: d.tabs.filter(match) }))
        .filter((d) => d.shown.length),
    [data, match, activeView]
  )
  const groupTotal = (data?.tabGroups || []).reduce(
    (n, g) => n + g.tabs.length,
    0
  )
  // tab count for what the current view shows (before search)
  const total =
    (activeView === "all" || activeView === "groups" ? groupTotal : 0) +
    (data?.devices || [])
      .filter((d) => activeView === "all" || activeView === `d:${d.name}`)
      .reduce((n, d) => n + d.tabs.length, 0)
  const groupMatches = groups.reduce((n, g) => n + g.shown.length, 0)
  const deviceMatches = devices.reduce((n, d) => n + d.shown.length, 0)
  const matches = groupMatches + deviceMatches
  const matchLabel = (n: number) => (n === 1 ? "1 match" : `${n} matches`)
  const firstMatch = q
    ? (groups[0]?.shown[0] ?? devices[0]?.shown[0])
    : undefined

  const openTab = async (url: string, background: boolean) => {
    if (!isWebUrl(url)) return // synced data could carry javascript:, data:, file: … never open those
    await api.tabs.create({ url, active: !background })
    if (!background && !IS_PAGE) window.close()
  }

  const doOpenAll = async (tabs: Tab[]) => {
    const web = tabs.filter((t) => isWebUrl(t.url))
    for (const t of web) await api.tabs.create({ url: t.url, active: false })
    toast.success(`Opened ${web.length} tabs`)
  }
  // Large batches ask first, in-app (window.confirm looks foreign here and is unreliable in Firefox popups).
  const openAll = (tabs: Tab[]) => {
    if (tabs.length <= 15) return doOpenAll(tabs)
    toast(`Open ${tabs.length} tabs?`, {
      description: "They open in the background.",
      action: { label: "Open", onClick: () => doOpenAll(tabs) },
      cancel: { label: "Cancel", onClick: () => {} },
    })
  }

  const openGroup = async (group: TabGroup) => {
    const win = await api.windows.getCurrent()
    const r = await api.runtime.sendMessage({
      type: "openGroup",
      group,
      windowId: win.id,
    })
    if (!r?.ok) {
      toast.error(r?.error || "Couldn't open the group")
      return
    }
    if (!IS_PAGE) window.close()
    else setLinked(await linkedGroupIds())
  }

  const copyFeed = async (group: TabGroup) => {
    let url: string
    try {
      url = await feedLink(settings, group)
    } catch (e) {
      toast.error("Couldn't get the feed address", {
        description: (e as Error).message,
      })
      return
    }
    await navigator.clipboard.writeText(url)
    toast.success(`Copied the feed for “${group.title}”`, {
      description: "In Zen, create a Live Folder, choose RSS and paste it.",
    })
  }

  const clearSearch = () => {
    setQuery("")
    searchRef.current?.focus()
  }

  const onSearchKey = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && firstMatch)
      openTab(firstMatch.url, e.metaKey || e.ctrlKey)
    if (e.key === "Escape" && query) {
      e.preventDefault()
      setQuery("")
    }
  }

  // Without any data, a problem fills the popup (Empty); with cached data it's a banner (Alert).
  const blocking = problem && !data && problem.kind !== "stale" ? problem : null
  const banner = problem && !blocking ? problem : null
  const openSettings = () => api.runtime.openOptionsPage()

  return (
    <div
      className={cn(
        "flex flex-col bg-background text-foreground",
        IS_PAGE ? "mx-auto h-svh max-w-2xl" : "h-[600px] w-[400px]"
      )}
    >
      <h1 className="sr-only">iCloud Tabs</h1>
      {/* One persistent live region, so result counts (including zero) are always announced. */}
      <p className="sr-only" role="status" aria-atomic="true">
        {q && data
          ? matches === 0
            ? "No matching tabs"
            : matches === 1
              ? "1 matching tab"
              : `${matches} matching tabs`
          : ""}
      </p>
      <div className="border-b">
        <header className="flex items-center gap-2 px-4 pt-3 pb-2.5">
          <InputGroup className="flex-1">
            <InputGroupAddon>
              <SearchIcon />
            </InputGroupAddon>
            <InputGroupInput
              ref={searchRef}
              autoFocus={!blocking}
              disabled={!!blocking}
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={onSearchKey}
              placeholder="Search tabs"
              aria-label="Search tabs"
              aria-keyshortcuts="/"
            />
            <InputGroupAddon align="inline-end">
              {query ? (
                <InputGroupButton
                  size="icon-xs"
                  aria-label="Clear search"
                  onClick={clearSearch}
                >
                  <XIcon />
                </InputGroupButton>
              ) : (
                !blocking && <Kbd aria-hidden>/</Kbd>
              )}
            </InputGroupAddon>
          </InputGroup>
          {!blocking && (
            <IconAction
              label="Refresh"
              icon={RefreshCwIcon}
              busy={loading}
              onClick={load}
            />
          )}
          {!IS_PAGE && (
            <IconAction
              label="Open in a tab"
              icon={Maximize2Icon}
              onClick={() => {
                api.tabs.create({ url: api.runtime.getURL("popup.html?page") })
                window.close()
              }}
            />
          )}
          <IconAction
            label="Settings"
            icon={SettingsIcon}
            onClick={openSettings}
          />
        </header>
        {!data && loading && !blocking && <ChipSkeleton />}
        {data && !blocking && (
          <ViewFilter
            value={q ? "all" : chosenView}
            searching={!!q}
            onChange={chooseView}
            groupCount={groupTotal}
            groupsLength={(data.tabGroups || []).length}
            hasGroups={(data.tabGroups || []).length > 0}
            devices={data.devices}
          />
        )}
      </div>

      {blocking ? (
        <Empty className="flex-1">
          <EmptyHeader>
            <EmptyMedia
              variant="icon"
              className={cn(blocking.kind === "error" && "text-destructive")}
            >
              {blocking.kind === "setup" ? (
                <PlugIcon />
              ) : blocking.kind === "access" ? (
                <ShieldAlertIcon />
              ) : (
                <WifiOffIcon />
              )}
            </EmptyMedia>
            <EmptyTitle>{blocking.title}</EmptyTitle>
            <EmptyDescription>{blocking.detail}</EmptyDescription>
          </EmptyHeader>
          <EmptyContent className="flex-row justify-center gap-2">
            {blocking.kind === "error" ? (
              <>
                <Button
                  size="sm"
                  autoFocus
                  onClick={loading ? undefined : load}
                  aria-busy={loading}
                >
                  {loading && <Spinner data-icon="inline-start" />}
                  Try again
                </Button>
                <Button size="sm" variant="outline" onClick={openSettings}>
                  Settings
                </Button>
              </>
            ) : (
              <Button size="sm" autoFocus onClick={openSettings}>
                Open Settings
              </Button>
            )}
          </EmptyContent>
        </Empty>
      ) : (
        <ScrollArea className="min-h-0 flex-1 [&_[data-slot=scroll-area-viewport]>div]:!block">
          <div className="flex flex-col gap-5 px-2 pt-3 pb-4">
            {banner && (
              <Alert role="status" className="mx-2 w-auto">
                {banner.kind === "stale" ? <ClockAlertIcon /> : <WifiOffIcon />}
                <AlertTitle>
                  {banner.kind === "error"
                    ? `Offline · last copy from ${timeAgo(data?.updatedAt)}`
                    : banner.title}
                </AlertTitle>
                <AlertDescription>
                  <p>
                    {banner.kind === "error"
                      ? "Is the Mac awake and on Tailscale?"
                      : banner.detail}
                  </p>
                </AlertDescription>
                <AlertAction>
                  <Button
                    size="xs"
                    variant="outline"
                    onClick={loading ? undefined : load}
                    aria-busy={loading}
                  >
                    {loading && <Spinner data-icon="inline-start" />}
                    Retry
                  </Button>
                </AlertAction>
              </Alert>
            )}

            {!data && loading && <LoadingRows />}

            {groups.length > 0 && (
              <Section
                title="Tab groups"
                meta={
                  q
                    ? matchLabel(groupMatches)
                    : banner
                      ? `${total} tabs`
                      : `${total} tabs · ${timeAgo(data?.updatedAt)}`
                }
              >
                {groups.map((g) => (
                  <ListSection
                    key={g.id}
                    icon={iconForGroup(g.title)}
                    title={g.title}
                    count={g.shown.length}
                    total={g.tabs.length}
                    searching={!!q}
                    open={!!q || !!open[`g:${g.id}`]}
                    onOpenChange={(v) => toggle(`g:${g.id}`, v)}
                    badge={linked.has(g.id) ? "Synced" : undefined}
                    actionCount={CAN_GROUP ? 1 : 2}
                    query={q}
                    actions={
                      CAN_GROUP ? (
                        <IconAction
                          muted
                          size="icon-sm"
                          icon={FolderSymlinkIcon}
                          label={
                            linked.has(g.id)
                              ? `Show the ${g.title} tab group`
                              : `Open ${g.title} as a tab group (${g.tabs.length} tabs)`
                          }
                          onClick={() => openGroup(g)}
                        />
                      ) : (
                        <>
                          <IconAction
                            muted
                            size="icon-sm"
                            icon={RssIcon}
                            label={`Copy the “${g.title}” Live Folder feed for Zen`}
                            onClick={() => copyFeed(g)}
                          />
                          <IconAction
                            muted
                            size="icon-sm"
                            icon={ExternalLinkIcon}
                            label={`Open all ${g.tabs.length} tabs from ${g.title}`}
                            onClick={() => openAll(g.tabs)}
                          />
                        </>
                      )
                    }
                  >
                    {g.shown.map((t) => (
                      <TabRow
                        key={tabKey(t)}
                        tab={t}
                        onOpen={openTab}
                        active={t === firstMatch}
                        query={q}
                      />
                    ))}
                  </ListSection>
                ))}
              </Section>
            )}

            {devices.length > 0 && (
              <Section
                title="Open on your devices"
                meta={
                  q
                    ? matchLabel(deviceMatches)
                    : !groups.length
                      ? banner
                        ? `${total} tabs`
                        : `${total} tabs · ${timeAgo(data?.updatedAt)}`
                      : undefined
                }
              >
                {devices.map((d) => (
                  <ListSection
                    key={d.name}
                    icon={iconForDevice(d.kind)}
                    title={d.name}
                    subtitle={
                      d.lastModified ? timeAgo(d.lastModified) : undefined
                    }
                    count={d.shown.length}
                    total={d.tabs.length}
                    searching={!!q}
                    open={!!q || open[`d:${d.name}`] !== false}
                    onOpenChange={(v) => toggle(`d:${d.name}`, v)}
                    actions={
                      <IconAction
                        muted
                        size="icon-sm"
                        icon={ExternalLinkIcon}
                        label={`Open all ${d.tabs.length} tabs from ${d.name}`}
                        onClick={() => openAll(d.tabs)}
                      />
                    }
                  >
                    {d.shown.map((t) => (
                      <TabRow
                        key={tabKey(t)}
                        tab={t}
                        onOpen={openTab}
                        active={t === firstMatch}
                        query={q}
                      />
                    ))}
                  </ListSection>
                ))}
              </Section>
            )}

            {data && !groups.length && !devices.length && (
              <Empty className="py-12">
                <EmptyHeader>
                  <EmptyMedia variant="icon">
                    <SearchIcon />
                  </EmptyMedia>
                  <EmptyTitle>
                    {q
                      ? "No matching tabs"
                      : activeView === "all"
                        ? "No synced tabs"
                        : "No tabs here"}
                  </EmptyTitle>
                  <EmptyDescription>
                    {q
                      ? "Try another word, or clear the search."
                      : activeView === "all"
                        ? "Turn on Safari in iCloud settings on your iPhone and Mac."
                        : "Nothing is open here right now."}
                  </EmptyDescription>
                </EmptyHeader>
                {(q || activeView !== "all") && (
                  <EmptyContent>
                    {q ? (
                      <Button size="sm" variant="outline" onClick={clearSearch}>
                        Clear search
                      </Button>
                    ) : (
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => chooseView("all")}
                      >
                        Show all tabs
                      </Button>
                    )}
                  </EmptyContent>
                )}
              </Empty>
            )}
          </div>
        </ScrollArea>
      )}
    </div>
  )
}

/** "Safari’s iPad Pro" → "iPad Pro", "iPad de Alex" → "iPad": short chip labels (full name in the tooltip). */
function shortDeviceName(name: string): string {
  const s = name
    .replace(/^.+?['’]s\s+/i, "")
    .replace(/\s+de\s+\S.*$/i, "")
    .trim()
  return s || name
}

function ViewFilter({
  value,
  searching,
  onChange,
  groupCount,
  groupsLength,
  hasGroups,
  devices,
}: {
  value: string
  searching: boolean
  onChange: (v: string) => void
  groupCount: number
  groupsLength: number
  hasGroups: boolean
  devices: RelayData["devices"]
}) {
  const rowRef = useRef<HTMLDivElement>(null)
  const [moreRight, setMoreRight] = useState(false)
  const [moreLeft, setMoreLeft] = useState(false)
  const checkOverflow = () => {
    const el = rowRef.current
    if (!el) return
    setMoreRight(el.scrollLeft + el.clientWidth < el.scrollWidth - 2)
    setMoreLeft(el.scrollLeft > 2)
  }
  useEffect(() => {
    checkOverflow()
    const el = rowRef.current
    if (!el) return
    const ro = new ResizeObserver(checkOverflow)
    ro.observe(el)
    // chips grow when counts change (e.g. "iPhone 9" → "iPhone 52") while the row keeps its width
    if (el.firstElementChild) ro.observe(el.firstElementChild)
    return () => ro.disconnect()
  }, [devices.length, hasGroups])
  // vertical wheel scrolls the chip row sideways
  const onWheel = (e: React.WheelEvent<HTMLDivElement>) => {
    if (Math.abs(e.deltaY) > Math.abs(e.deltaX))
      e.currentTarget.scrollLeft += e.deltaY
  }
  if (!hasGroups && devices.length < 2) return null
  const count = (n: number) => (
    <span className="text-muted-foreground tabular-nums group-data-[state=on]/toggle:text-foreground/70">
      {n}
    </span>
  )
  return (
    // pt-0.5 leaves room for the 2px focus ring, which overflow-x-auto would otherwise clip.
    // A right-edge fade shows there are more chips until the row is scrolled to its end.
    <div
      ref={rowRef}
      onScroll={checkOverflow}
      onWheel={onWheel}
      className={cn(
        "[scrollbar-width:none] overflow-x-auto px-4 pt-0.5 pb-3 [&::-webkit-scrollbar]:hidden",
        moreRight &&
          !moreLeft &&
          "[mask-image:linear-gradient(to_right,black_calc(100%-32px),transparent)]",
        moreLeft &&
          !moreRight &&
          "[mask-image:linear-gradient(to_left,black_calc(100%-32px),transparent)]",
        moreLeft &&
          moreRight &&
          "[mask-image:linear-gradient(to_right,transparent,black_32px,black_calc(100%-32px),transparent)]"
      )}
      title={searching ? "Search covers all tabs" : undefined}
    >
      <ToggleGroup
        type="single"
        variant="outline"
        size="sm"
        value={value}
        onValueChange={onChange}
        disabled={searching}
        aria-label={
          searching
            ? "Show tabs from (search covers all tabs)"
            : "Show tabs from"
        }
        className="w-max"
      >
        <ToggleGroupItem value="all">All</ToggleGroupItem>
        {hasGroups && (
          <ToggleGroupItem
            value="groups"
            title={`${groupCount} tabs in ${groupsLength} groups`}
            aria-label={`Groups ${groupCount}, ${groupCount} tabs in ${groupsLength} groups`}
          >
            <FoldersIcon data-icon="inline-start" />
            Groups {count(groupCount)}
          </ToggleGroupItem>
        )}
        {devices.map((d) => {
          const Icon = iconForDevice(d.kind)
          return (
            <ToggleGroupItem
              key={d.name}
              value={`d:${d.name}`}
              title={d.name}
              aria-label={`${shortDeviceName(d.name)} ${d.tabs.length}, tabs open on ${d.name}`}
            >
              <Icon data-icon="inline-start" />
              {shortDeviceName(d.name)} {count(d.tabs.length)}
            </ToggleGroupItem>
          )
        })}
      </ToggleGroup>
    </div>
  )
}

function ChipSkeleton() {
  return (
    <div className="flex gap-2 px-4 pt-0.5 pb-3" aria-hidden>
      {["w-10", "w-24", "w-20", "w-24"].map((w, i) => (
        <Skeleton key={i} className={cn("h-7 rounded-md bg-accent", w)} />
      ))}
    </div>
  )
}

function Section({
  title,
  meta,
  children,
}: {
  title: string
  meta?: ReactNode
  children: ReactNode
}) {
  return (
    <section className="flex flex-col" aria-label={title}>
      <div className="flex items-baseline justify-between gap-2 px-2 pb-1.5">
        <h2 className="text-xs font-medium text-muted-foreground">{title}</h2>
        {meta && (
          <span className="text-xs text-muted-foreground tabular-nums">
            {meta}
          </span>
        )}
      </div>
      {children}
    </section>
  )
}

function ListSection({
  actionCount = 1,
  icon: Icon,
  title,
  subtitle,
  count,
  total,
  searching,
  badge,
  query,
  open,
  onOpenChange,
  actions,
  children,
}: {
  actionCount?: number
  icon: LucideIcon
  title: string
  subtitle?: string
  count: number
  total: number
  searching: boolean
  badge?: string
  query?: string
  open: boolean
  onOpenChange: (v: boolean) => void
  actions?: ReactNode
  children: ReactNode
}) {
  const [kbFocus, setKbFocus] = useState(false)
  const nameRef = useRef<HTMLSpanElement>(null)
  return (
    <Collapsible open={open} onOpenChange={onOpenChange}>
      <div className="group/row relative flex items-center rounded-lg hover:bg-accent has-focus-visible:bg-accent">
        <CollapsibleTrigger
          disabled={searching}
          onFocus={(e) => {
            if (!e.currentTarget.matches(":focus-visible")) return
            setKbFocus(isTruncated(nameRef.current))
            // the title gives way to the action overlay over 150ms; measure again once it has
            const t = e.currentTarget
            setTimeout(() => {
              if (document.activeElement === t)
                setKbFocus(isTruncated(nameRef.current))
            }, 200)
          }}
          onBlur={() => setKbFocus(false)}
          className="flex h-11 min-w-0 flex-1 items-center gap-3 rounded-lg px-2 text-left outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset disabled:cursor-default"
        >
          <span
            className="grid size-7 shrink-0 place-items-center rounded-md border bg-muted text-foreground [&>svg]:size-4"
            aria-hidden
          >
            <Icon />
          </span>
          {/* Title + badge give way while the action overlay shows, so long names truncate instead of
              running underneath it (16px for one action, 48px for Zen's two). */}
          <span
            className={cn(
              "flex min-w-0 flex-1 items-center gap-2 transition-[margin] duration-150 motion-reduce:transition-none",
              actionCount === 1 &&
                "group-focus-within/row:mr-4 group-hover/row:mr-4 [@media(hover:none)]:mr-4",
              actionCount >= 2 &&
                "group-focus-within/row:mr-12 group-hover/row:mr-12 [@media(hover:none)]:mr-12"
            )}
          >
            <span className="flex min-w-0 flex-1 items-baseline gap-2">
              <TruncatedName
                text={title}
                query={query}
                focusOpen={kbFocus}
                nameRef={nameRef}
              />
              {subtitle && (
                <span className="shrink-0 text-xs text-muted-foreground">
                  {subtitle}
                </span>
              )}
            </span>
            {badge && (
              <Badge variant="outline" className="shrink-0">
                {badge}
              </Badge>
            )}
          </span>
          {/* The visible count hides under the actions; the accessible count lives outside it. */}
          <span className="sr-only">
            {searching && count !== total
              ? `, ${count} of ${total} tabs match`
              : `, ${total} tabs`}
          </span>
          <span
            aria-hidden
            className={cn(
              "shrink-0 text-xs text-muted-foreground tabular-nums",
              // the hover actions are drawn over the count, so it steps aside
              actions &&
                "group-focus-within/row:invisible group-hover/row:invisible [@media(hover:none)]:invisible"
            )}
          >
            {searching && count !== total ? `${count} of ${total}` : total}
          </span>
          <ChevronRightIcon
            className={cn(
              "size-4 shrink-0 text-muted-foreground transition-transform motion-reduce:transition-none",
              open && "rotate-90",
              searching && "invisible"
            )}
            aria-hidden
          />
        </CollapsibleTrigger>
        {/* Actions are drawn over the count on hover or focus (always on touch), so counts and
            chevrons stay flush right in every row and the list stays calm. Linked groups show a badge. */}
        {actions && (
          <div
            className={cn(
              "pointer-events-none absolute inset-y-0 right-8 flex items-center gap-0.5 rounded-md bg-accent pl-1 opacity-0",
              "transition-opacity motion-reduce:transition-none",
              "group-hover/row:pointer-events-auto group-hover/row:opacity-100",
              "group-focus-within/row:pointer-events-auto group-focus-within/row:opacity-100",
              "[@media(hover:none)]:pointer-events-auto [@media(hover:none)]:opacity-100"
            )}
          >
            {actions}
          </div>
        )}
      </div>
      <CollapsibleContent className="overflow-hidden data-[state=closed]:animate-collapsible-up data-[state=open]:animate-collapsible-down motion-reduce:animate-none">
        <ul className="flex flex-col pt-0.5 pb-1.5">{children}</ul>
      </CollapsibleContent>
    </Collapsible>
  )
}

function TabRow({
  tab,
  onOpen,
  active,
  query,
}: {
  tab: Tab
  onOpen: (url: string, background: boolean) => void
  active?: boolean
  query?: string
}) {
  const host = hostOf(tab.url)
  const [darkIcon, setDarkIcon] = useState(false)
  const icon = faviconFor(tab.url)
  const web = isWebUrl(tab.url)
  return (
    <li>
      <a
        href={web ? tab.url : undefined}
        aria-disabled={web ? undefined : true}
        title={`${tab.title}\n${tab.url}`}
        data-active={active || undefined}
        aria-keyshortcuts={active ? "Enter" : undefined}
        onClick={(e) => {
          e.preventDefault()
          onOpen(tab.url, e.metaKey || e.ctrlKey || e.shiftKey)
        }}
        onAuxClick={(e) => {
          if (e.button === 1) {
            e.preventDefault()
            onOpen(tab.url, true)
          }
        }}
        className="flex h-11 items-center gap-3 rounded-lg px-2 outline-none hover:bg-accent focus-visible:bg-accent focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset data-active:bg-accent"
      >
        {/* Same 28px column as the group icon tile above, so icons and titles line up. */}
        <span className="grid size-7 shrink-0 place-items-center" aria-hidden>
          <Avatar
            className={cn(
              "size-5 rounded-[5px] bg-muted p-0.5 ring-1 ring-border after:hidden",
              darkIcon && "bg-foreground/90"
            )}
          >
            <AvatarImage
              src={icon}
              alt=""
              onLoad={(e) => setDarkIcon(isDarkImage(e.currentTarget))}
              className="rounded-[3px] object-contain"
            />
            <AvatarFallback className="rounded-[3px] bg-transparent text-[11px] font-semibold text-foreground/80 uppercase">
              {host[0] || "?"}
            </AvatarFallback>
          </Avatar>
        </span>
        <span className="flex min-w-0 flex-1 flex-col">
          <span className="flex items-center gap-1.5">
            <span className="truncate text-sm">
              <Highlight text={tab.title} query={query} />
            </span>
            {tab.pinned && (
              <>
                <PinIcon
                  className="size-3 shrink-0 text-muted-foreground"
                  aria-hidden
                />
                <span className="sr-only">, pinned</span>
              </>
            )}
          </span>
          <span className="truncate text-xs text-muted-foreground">
            <Highlight text={host} query={query} />
          </span>
        </span>
        {active && <Kbd className="shrink-0">↵</Kbd>}
      </a>
    </li>
  )
}

function IconAction({
  label,
  icon: Icon,
  onClick,
  busy,
  muted,
  size = "icon",
}: {
  label: string
  icon: LucideIcon
  onClick: () => void
  busy?: boolean
  muted?: boolean
  size?: "icon" | "icon-sm"
}) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button
          variant="ghost"
          size={size}
          aria-label={label}
          aria-busy={busy || undefined}
          onClick={busy ? undefined : onClick}
          className={cn(muted && "text-muted-foreground hover:text-foreground")}
        >
          {busy ? <Spinner /> : <Icon />}
        </Button>
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  )
}

const SKELETON_WIDTHS = [
  "w-2/5",
  "w-1/2",
  "w-1/3",
  "w-3/5",
  "w-1/4",
  "w-2/5",
  "w-1/2",
]

function LoadingRows() {
  return (
    <div className="flex flex-col" role="status" aria-busy="true">
      <span className="sr-only">Loading tabs</span>
      <div
        className="flex items-center justify-between px-2 pb-1.5"
        aria-hidden
      >
        <Skeleton className="h-3 w-20 bg-accent" />
        <Skeleton className="h-3 w-24 bg-accent" />
      </div>
      {SKELETON_WIDTHS.map((w, i) => (
        <div key={i} className="flex h-11 items-center gap-3 px-2" aria-hidden>
          <Skeleton className="size-7 rounded-md border bg-accent" />
          <Skeleton className={cn("h-3.5 bg-accent", w)} />
          <Skeleton className="ml-auto h-3 w-4 bg-accent" />
          <span className="size-4" />
        </div>
      ))}
    </div>
  )
}

/** Group name that shows its full text in a tooltip, on hover or focus, only when it's cut off. */
const isTruncated = (el: HTMLElement | null) =>
  !!el && el.scrollWidth > el.clientWidth + 1

/**
 * Group name that shows its full text in a tooltip only when it's cut off: on hover, or when the
 * row's trigger gets keyboard focus (`focusOpen`, measured by the row).
 */
function TruncatedName({
  text,
  query,
  focusOpen,
  nameRef,
}: {
  text: string
  query?: string
  focusOpen?: boolean
  nameRef: React.RefObject<HTMLSpanElement | null>
}) {
  const [hoverOpen, setHoverOpen] = useState(false)
  return (
    <Tooltip open={hoverOpen || !!focusOpen}>
      <TooltipTrigger asChild>
        <span
          ref={nameRef}
          onPointerEnter={() => setHoverOpen(isTruncated(nameRef.current))}
          onPointerLeave={() => setHoverOpen(false)}
          className="truncate text-sm font-medium"
        >
          <Highlight text={text} query={query} />
        </span>
      </TooltipTrigger>
      <TooltipContent aria-hidden>{text}</TooltipContent>
    </Tooltip>
  )
}

/** Bold the matched part of a title or host while searching. */
function Highlight({ text, query }: { text: string; query?: string }) {
  if (!query) return <>{text}</>
  const i = text.toLowerCase().indexOf(query)
  if (i < 0) return <>{text}</>
  return (
    <>
      {text.slice(0, i)}
      <mark className="bg-transparent font-semibold text-foreground">
        {text.slice(i, i + query.length)}
      </mark>
      {text.slice(i + query.length)}
    </>
  )
}

/** True when a favicon is mostly dark, so it gets a light tile instead of vanishing on black. */
function isDarkImage(img: HTMLImageElement): boolean {
  try {
    const size = 16
    const canvas = document.createElement("canvas")
    canvas.width = canvas.height = size
    const ctx = canvas.getContext("2d", { willReadFrequently: true })
    if (!ctx) return false
    ctx.drawImage(img, 0, 0, size, size)
    const px = ctx.getImageData(0, 0, size, size).data
    let sum = 0
    let count = 0
    for (let i = 0; i < px.length; i += 4) {
      if (px[i + 3] < 128) continue
      sum += (0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2]) / 255
      count++
    }
    return count > 0 && sum / count < 0.3
  } catch {
    return false // tainted canvas or decode error: keep the default tile
  }
}
