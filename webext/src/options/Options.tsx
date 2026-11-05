import { useEffect, useRef, useState } from "react"
import {
  CheckCircle2Icon,
  CloudIcon,
  EyeIcon,
  EyeOffIcon,
  FolderTreeIcon,
  ShieldIcon,
  TriangleAlertIcon,
} from "lucide-react"

import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import {
  Field,
  FieldDescription,
  FieldError,
  FieldGroup,
  FieldLabel,
} from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import {
  InputGroup,
  InputGroupAddon,
  InputGroupButton,
  InputGroupInput,
} from "@/components/ui/input-group"
import { Spinner } from "@/components/ui/spinner"
import {
  api,
  clearSavedData,
  fetchJson,
  getSettings,
  IS_GECKO,
  normalizeUrl,
  originPattern,
} from "@/lib/ext"
import { clearFavicons } from "@/lib/favicons"

type Result = { ok: boolean; text: string; title?: string } | null

export function Options() {
  const [relayUrl, setRelayUrl] = useState("")
  const [token, setToken] = useState("")
  const [showToken, setShowToken] = useState(false)
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState<Result>(null)
  const [urlError, setUrlError] = useState("")
  const urlRef = useRef<HTMLInputElement>(null)
  // Bumped on every edit so a slow test can't report on values the user has since changed.
  const revision = useRef(0)
  const edited = () => {
    revision.current++
    setResult(null)
  }

  useEffect(() => {
    getSettings().then((s) => {
      setRelayUrl(s.relayUrl)
      setToken(s.token)
    })
  }, [])

  const [shortcut, setShortcut] = useState("")
  useEffect(() => {
    api.commands
      ?.getAll()
      .then((cmds) =>
        setShortcut(
          cmds.find((c) => c.name === "_execute_action")?.shortcut || ""
        )
      )
      .catch(() => {})
  }, [])

  const save = async (e: React.FormEvent) => {
    e.preventDefault()
    if (busy) return
    // Snapshot the submitted values and the edit revision before anything async. If the user edits
    // either field while the permission prompt or the test is pending, the run is abandoned quietly.
    const rev = revision.current
    const current = () => rev === revision.current
    const submittedToken = token.trim()
    let url: string
    try {
      url = normalizeUrl(relayUrl)
      if (!url) throw new Error()
    } catch {
      setUrlError("Enter an address like http://your-mac.ts.net:8787")
      urlRef.current?.focus()
      return
    }
    setUrlError("")
    if (!submittedToken) {
      setResult({
        ok: false,
        text: "Enter the token. The relay won't answer without one.",
      })
      return
    }
    setResult(null)
    setBusy(true)
    try {
      // Must stay the first await in the submit handler: both browsers require a user gesture.
      let granted = false
      try {
        granted = await api.permissions.request({
          origins: [originPattern(url)],
        })
      } catch (err) {
        if (current())
          setResult({
            ok: false,
            text: `The permission request failed: ${(err as Error).message}`,
          })
        return
      }
      if (!current()) return
      if (!granted) {
        setResult({
          ok: false,
          text: "The browser didn't allow access to that address.",
        })
        return
      }
      setRelayUrl(url)
      // A different relay or token means different data: drop what was saved from the old one.
      const before = await getSettings()
      if (
        before.relayUrl &&
        (before.relayUrl !== url || before.token !== submittedToken)
      ) {
        await clearSavedData()
        await clearFavicons()
      }
      await api.storage.local.set({ relayUrl: url, token: submittedToken })
      let d
      try {
        d = await fetchJson(url, submittedToken)
      } catch (err) {
        if (current())
          setResult({
            ok: false,
            text: `Saved, but the test failed. ${(err as Error).message}`,
          })
        return
      }
      await api.storage.local.set({ cache: d })
      if (!current()) return
      if (d.stale) {
        setResult({
          ok: false,
          text: `The relay answered, but it can't read Safari right now. ${d.error || ""}`.trim(),
        })
        return
      }
      const tabs =
        d.devices.reduce((n, x) => n + x.tabs.length, 0) +
        (d.tabGroups || []).reduce((n, g) => n + g.tabs.length, 0)
      setResult({
        ok: true,
        text: `${tabs} tabs in ${(d.tabGroups || []).length} groups and ${d.devices.length} devices.`,
      })
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="mx-auto flex min-h-svh max-w-lg flex-col gap-6 px-6 py-12">
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-3">
            <span
              className="grid size-8 place-items-center rounded-lg border bg-muted [&>svg]:size-4"
              aria-hidden
            >
              <CloudIcon />
            </span>
            <h1 className="text-lg font-semibold">iCloud Tabs Relay</h1>
          </CardTitle>
          <CardDescription className="text-pretty">
            Connect to the relay on your Mac. Its install script prints both
            values.
          </CardDescription>
        </CardHeader>
        <form onSubmit={save} noValidate>
          <CardContent>
            <FieldGroup>
              <Field data-invalid={!!urlError || undefined}>
                <FieldLabel htmlFor="relayUrl">Relay address</FieldLabel>
                <Input
                  ref={urlRef}
                  id="relayUrl"
                  className="text-foreground"
                  value={relayUrl}
                  onChange={(e) => {
                    setRelayUrl(e.target.value)
                    setUrlError("")
                    edited()
                  }}
                  placeholder="http://your-mac.tailnet.ts.net:8787"
                  spellCheck={false}
                  autoComplete="off"
                  aria-invalid={!!urlError || undefined}
                  aria-describedby={
                    urlError ? "relayUrl-error relayUrl-desc" : "relayUrl-desc"
                  }
                />
                <FieldDescription id="relayUrl-desc">
                  Your Mac's Tailscale name or 100.x address, with the port.
                </FieldDescription>
                {urlError && (
                  <FieldError id="relayUrl-error">{urlError}</FieldError>
                )}
              </Field>
              <Field>
                <FieldLabel htmlFor="token">Token</FieldLabel>
                <InputGroup>
                  <InputGroupInput
                    id="token"
                    type={showToken ? "text" : "password"}
                    value={token}
                    onChange={(e) => {
                      setToken(e.target.value)
                      edited()
                    }}
                    spellCheck={false}
                    autoComplete="off"
                    aria-describedby="token-desc"
                  />
                  <InputGroupAddon align="inline-end">
                    <InputGroupButton
                      size="icon-xs"
                      aria-label={showToken ? "Hide token" : "Show token"}
                      aria-pressed={showToken}
                      onClick={() => setShowToken((v) => !v)}
                    >
                      {showToken ? <EyeOffIcon /> : <EyeIcon />}
                    </InputGroupButton>
                  </InputGroupAddon>
                </InputGroup>
                <FieldDescription id="token-desc">
                  Kept only in this browser. On the Mac, click Copy Token in TabTunnel’s Status page or
                  Settings › Sharing.
                </FieldDescription>
              </Field>
            </FieldGroup>
          </CardContent>
          <CardFooter className="mt-6 flex-col items-stretch gap-4">
            <Button type="submit" aria-busy={busy} className="self-start">
              {busy && <Spinner data-icon="inline-start" />}
              {busy ? "Testing" : "Save and test"}
            </Button>
            {result && (
              <Alert
                variant={result.ok ? "default" : "destructive"}
                aria-live="polite"
              >
                {result.ok ? <CheckCircle2Icon /> : <TriangleAlertIcon />}
                <AlertTitle>
                  {result.title ??
                    (result.ok ? "Connected" : "Something's wrong")}
                </AlertTitle>
                <AlertDescription className="[&_p:not(:last-child)]:mb-1">
                  <p>{result.text}</p>
                  {result.ok && !result.title && (
                    <p>
                      Open the extension from the toolbar
                      {shortcut ? `, or press ${shortcut}` : ""}.
                    </p>
                  )}
                </AlertDescription>
              </Alert>
            )}
          </CardFooter>
        </form>
      </Card>

      {IS_GECKO && (
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-3">
              <span
                className="grid size-8 place-items-center rounded-lg border bg-muted [&>svg]:size-4"
                aria-hidden
              >
                <FolderTreeIcon />
              </span>
              <h2 className="text-base font-semibold">
                Safari groups as Zen folders
              </h2>
            </CardTitle>
            <CardDescription>
              Zen's Live Folders keep each group in sync on their own.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <ol className="flex list-decimal flex-col gap-2 pl-5 text-sm text-muted-foreground">
              <li>
                In the popup, hover or keyboard-focus a group, then choose its
                RSS button.
              </li>
              <li>
                In Zen, create a Live Folder, choose RSS and paste the address.
              </li>
              <li>In the folder's menu, set the item limit to 50.</li>
            </ol>
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-3">
            <span
              className="grid size-8 place-items-center rounded-lg border bg-muted [&>svg]:size-4"
              aria-hidden
            >
              <ShieldIcon />
            </span>
            <h2 className="text-base font-semibold">Saved data</h2>
          </CardTitle>
          <CardDescription className="text-pretty">
            So the list works while your Mac is off, this browser keeps the last
            copy of your tabs and their icons. Clearing it removes them here;
            nothing on your Mac changes.
          </CardDescription>
        </CardHeader>
        <CardFooter>
          <Button
            variant="outline"
            onClick={async () => {
              await clearSavedData()
              await clearFavicons()
              setResult({
                ok: true,
                title: "Cleared",
                text: "Saved tabs and icons were removed from this browser.",
              })
            }}
          >
            Clear saved data
          </Button>
        </CardFooter>
      </Card>
    </main>
  )
}
