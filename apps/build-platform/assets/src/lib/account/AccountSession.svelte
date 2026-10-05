<script lang="ts">
import { onMount, tick } from "svelte"
import { routes } from "$phoenix/routes"
import type { SessionView } from "$phoenix/types"

let view = $state<SessionView | null>(null)
let known = $state(false)
let busy = $state(false)
let message = $state("")
let account: HTMLDetailsElement

async function focusControl() {
  await tick()
  account.querySelector<HTMLElement>("input, button")?.focus()
}

function session(value: unknown): SessionView {
  if (
    typeof value !== "object" ||
    value === null ||
    Object.keys(value).sort().join(",") !== "authenticated,csrf_token" ||
    !("authenticated" in value) ||
    typeof value.authenticated !== "boolean" ||
    !("csrf_token" in value) ||
    typeof value.csrf_token !== "string" ||
    !/^[A-Za-z0-9_-]{1,128}$/.test(value.csrf_token)
  )
    throw new Error("unavailable")
  return value as SessionView
}

async function refresh(manual = false) {
  if (busy) return
  busy = true
  message = ""
  try {
    const response = await fetch(routes.sessionShow(), {
      credentials: "same-origin",
      cache: "no-store",
      signal: AbortSignal.timeout(15_000),
    })
    if (!response.ok) throw new Error("unavailable")
    view = session(await response.json())
    known = true
  } catch {
    known = false
    message = "Account status is temporarily unavailable."
  } finally {
    busy = false
    if (manual) await focusControl()
  }
}

async function signIn(event: SubmitEvent) {
  event.preventDefault()
  if (busy || !known || !view) return
  const form = event.currentTarget as HTMLFormElement
  const data = new FormData(form)
  const email = data.get("email")
  const password = data.get("password")
  if (
    typeof email !== "string" ||
    typeof password !== "string" ||
    password.length === 0 ||
    Array.from(password).length > 128 ||
    new TextEncoder().encode(email).length > 254
  ) {
    message = "Check your email and password. Passwords can contain up to 128 characters."
    form.querySelector<HTMLInputElement>('input[name="password"]')!.value = ""
    return
  }
  busy = true
  message = ""
  try {
    const response = await fetch(routes.create(), {
      method: "POST",
      credentials: "same-origin",
      cache: "no-store",
      headers: { "content-type": "application/json", "x-csrf-token": view.csrf_token },
      body: JSON.stringify({ email, password }),
      signal: AbortSignal.timeout(15_000),
    })
    if (response.status === 400) {
      message = "Check your email and password."
      return
    }
    if (response.status === 401) {
      message = "Email or password was not accepted."
      return
    }
    if (response.status === 429) {
      message = "Too many sign-in attempts. Try again in a minute."
      return
    }
    if (!response.ok) throw new Error("unavailable")
    const current = session(await response.json())
    if (!current.authenticated) throw new Error("unavailable")
    view = current
    known = true
    message = "Signed in."
  } catch {
    known = false
    message = "Sign-in could not be confirmed. Check account status before trying again."
  } finally {
    form.querySelector<HTMLInputElement>('input[name="password"]')!.value = ""
    busy = false
    if (!known || view?.authenticated) await focusControl()
  }
}

async function signOut() {
  if (busy || !known || !view) return
  busy = true
  message = ""
  try {
    const response = await fetch(routes.delete(), {
      method: "DELETE",
      credentials: "same-origin",
      cache: "no-store",
      headers: { "content-type": "application/json", "x-csrf-token": view.csrf_token },
      body: "{}",
      signal: AbortSignal.timeout(15_000),
    })
    if (!response.ok) throw new Error("unavailable")
    const current = session(await response.json())
    if (current.authenticated) throw new Error("unavailable")
    view = current
    known = true
    message = "Signed out."
  } catch {
    known = false
    message = "Sign-out could not be confirmed. Check account status before trying again."
  } finally {
    busy = false
    await focusControl()
  }
}

onMount(() => {
  void refresh()
})
</script>

<details class="account" bind:this={account}>
  <summary>Account{#if known && view?.authenticated}<span> · Signed in</span>{/if}</summary>
  <section class="panel" aria-labelledby="account-heading" aria-busy={busy}>
    <h2 id="account-heading">Your account</h2>
    <p class="intro">Browse component evidence without signing in.</p>
    <div class="status" role="status" aria-live="polite" aria-atomic="true">
      {#if busy}<p>Checking account…</p>{:else if message}<p>{message}</p>{/if}
      {#if !known && view?.authenticated}<p>Last verified status: signed in.</p>{/if}
    </div>
    {#if !known}
      <button onclick={() => refresh(true)} disabled={busy}>Check account status</button>
    {:else if view?.authenticated}
      <p>Signed in.</p>
      <button onclick={signOut} disabled={busy}>Sign out</button>
    {:else}
      <form onsubmit={signIn} novalidate>
        <label>Email<input name="email" type="email" autocomplete="username" required disabled={busy} /></label>
        <label>Password<input name="password" type="password" autocomplete="current-password" required disabled={busy} /></label>
        <button type="submit" disabled={busy}>Sign in</button>
      </form>
    {/if}
  </section>
</details>

<style>
  .account { flex-shrink: 0; }
  summary { cursor: pointer; font-size: 0.8rem; font-weight: 650; }
  summary span { color: var(--fs-muted); font-weight: 400; }
  .panel {
    position: absolute; right: 0; top: calc(100% + 0.75rem); z-index: 5;
    width: min(22rem, calc(100vw - 2rem)); box-sizing: border-box;
    padding: 1.5rem; background: var(--fs-paper); border: 1px solid var(--fs-line-strong);
    box-shadow: 0 0.5rem 2rem rgb(0 0 0 / 8%);
  }
  h2 { margin: 0; font-size: 1.2rem; }
  .intro, .status { color: var(--fs-muted); font-size: 0.85rem; line-height: 1.5; }
  .intro { margin: 0.75rem 0 1.25rem; }
  .status p { margin: 0 0 1rem; }
  form, label { display: grid; gap: 0.5rem; }
  form { gap: 1rem; }
  label { font-size: 0.85rem; font-weight: 650; }
  input {
    min-width: 0; width: 100%; box-sizing: border-box; padding: 0.65rem;
    border: 1px solid var(--fs-line-strong); border-radius: var(--fs-control-radius);
    color: var(--fs-ink); background: var(--fs-paper); font: inherit; font-size: 1rem;
  }
  button {
    border: 1px solid var(--fs-ink); border-radius: var(--fs-control-radius);
    background: var(--fs-ink); color: white; padding: 0.75rem 1rem;
    font: inherit; font-size: 0.85rem; font-weight: 650; cursor: pointer;
  }
  button:disabled { opacity: 0.6; cursor: wait; }
</style>
