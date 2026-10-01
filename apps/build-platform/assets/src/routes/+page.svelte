<script lang="ts">
import { onMount } from "svelte"
import type { ProfileRevision, SourceDocument } from "$phoenix/types"

type Page<T> = { data: T[]; more: boolean; offset: number }

let profiles = $state<ProfileRevision[]>([])
let profilePage = $state({ loading: false, loaded: false, error: false, more: false })
let profileOffset = $state(0)
let sources = $state<SourceDocument[]>([])
let sourcePage = $state({ loading: false, loaded: false, error: false, more: false })
let sourceOffset = $state(0)

async function fetchPage<T>(path: string, offset: number): Promise<Page<T>> {
  const response = await fetch(`${path}?offset=${offset}`)
  if (!response.ok) throw new Error("unavailable")

  const page: unknown = await response.json()
  if (
    typeof page !== "object" ||
    page === null ||
    !("data" in page) ||
    !Array.isArray(page.data) ||
    !("more" in page) ||
    typeof page.more !== "boolean" ||
    !("offset" in page) ||
    page.offset !== offset
  )
    throw new Error("invalid_page")

  return page as Page<T>
}

async function loadProfiles() {
  if (profilePage.loading) return
  profilePage.loading = true
  profilePage.error = false

  try {
    const page = await fetchPage<ProfileRevision>("/api/profiles", profileOffset)
    const seen = new Set(profiles.map((profile) => profile.id))
    profiles = [...profiles, ...page.data.filter((profile) => !seen.has(profile.id))]
    profileOffset += page.data.length
    profilePage.more = page.more && page.data.length > 0 && profileOffset <= 10_000
    profilePage.loaded = true
  } catch {
    profilePage.error = true
  } finally {
    profilePage.loading = false
  }
}

async function loadSources() {
  if (sourcePage.loading) return
  sourcePage.loading = true
  sourcePage.error = false

  try {
    const page = await fetchPage<SourceDocument>("/api/sources", sourceOffset)
    const seen = new Set(sources.map((source) => source.id))
    sources = [...sources, ...page.data.filter((source) => !seen.has(source.id))]
    sourceOffset += page.data.length
    sourcePage.more = page.more && page.data.length > 0 && sourceOffset <= 10_000
    sourcePage.loaded = true
  } catch {
    sourcePage.error = true
  } finally {
    sourcePage.loading = false
  }
}

onMount(() => {
  void loadProfiles()
  void loadSources()
})
</script>

<svelte:head>
  <title>Frameshift · Component evidence</title>
  <meta
    name="description"
    content="Candidate frame component profiles and exact source revisions, with qualification limits kept visible."
  />
</svelte:head>

<main>
  <header class="masthead">
    <a class="brand" href="/" aria-label="Frameshift component evidence">
      <strong>Frameshift</strong>
      <span>Component evidence</span>
    </a>
    <p class="catalog-state"><span aria-hidden="true"></span> Public catalog · Read only</p>
  </header>

  <section class="brief" aria-labelledby="page-heading">
    <div>
      <p class="eyebrow">Planning evidence</p>
      <h1 id="page-heading">Review component evidence</h1>
    </div>
    <p>
      Inspect candidate profile bytes and their source revisions before planning a frame.
      Candidate status never approves a complete assembly.
    </p>
  </section>

  <section class="register" aria-labelledby="profiles-heading">
    <header class="section-heading">
      <p class="index">01</p>
      <div>
        <h2 id="profiles-heading">Candidate profiles</h2>
        <p>Download the exact immutable profile. Physical compatibility remains unresolved.</p>
      </div>
      {#if profilePage.loaded}<p class="count">{profiles.length} recorded</p>{/if}
    </header>

    <div aria-live="polite">
      {#if !profilePage.loaded && !profilePage.error}
        <p class="message">Loading candidate profiles…</p>
      {:else if !profilePage.loaded && profilePage.error}
        <div class="message action-message">
          <p>Candidate profiles are temporarily unavailable.</p>
          <button class="primary" onclick={loadProfiles}>Try again</button>
        </div>
      {:else if profilePage.loaded && profiles.length === 0}
        <p class="message">No candidate profiles have been recorded in this catalog.</p>
      {:else}
        <ul class="profile-list">
          {#each profiles as profile (profile.id)}
            <li>
              <div class="profile-status">
                <span>Candidate</span>
                <small>Qualification unresolved</small>
              </div>
              <div class="profile-identity">
                <h3>{profile.label}</h3>
                <p>{profile.classes.join(" · ") || "Unclassified component"}</p>
              </div>
              <dl>
                <div><dt>Kind</dt><dd>{profile.kind}</dd></div>
                <div><dt>Revision</dt><dd>{profile.profile_revision}</dd></div>
              </dl>
              <a class="download" href={`/api/profiles/${profile.identity.slice(7)}`} download>
                Download exact profile <span aria-hidden="true">↓</span>
              </a>
            </li>
          {/each}
        </ul>
        {#if profilePage.error}
          <p class="inline-error" role="status">More profiles are temporarily unavailable.</p>
        {/if}
        {#if profilePage.more || profilePage.error}
          <button class="secondary" onclick={loadProfiles} disabled={profilePage.loading}>
            {profilePage.loading ? "Loading…" : profilePage.error ? "Try again" : "Load more profiles"}
          </button>
        {/if}
      {/if}
    </div>
  </section>

  <section class="register" aria-labelledby="sources-heading">
    <header class="section-heading">
      <p class="index">02</p>
      <div>
        <h2 id="sources-heading">Source documents</h2>
        <p>A source records provenance. It does not establish that an assembly was tested.</p>
      </div>
      {#if sourcePage.loaded}<p class="count">{sources.length} recorded</p>{/if}
    </header>

    <div aria-live="polite">
      {#if !sourcePage.loaded && !sourcePage.error}
        <p class="message">Loading source records…</p>
      {:else if !sourcePage.loaded && sourcePage.error}
        <div class="message action-message">
          <p>Source records are temporarily unavailable.</p>
          <button class="primary" onclick={loadSources}>Try again</button>
        </div>
      {:else if sourcePage.loaded && sources.length === 0}
        <p class="message">No source documents have been recorded in this catalog.</p>
      {:else}
        <ul class="source-list">
          {#each sources as source (source.id)}
            <li>
              <span class="source-kind">{source.kind}</span>
              <div>
                <a href={source.uri} target="_blank" rel="noopener noreferrer">{source.title}</a>
                <p>Revision {source.revision}</p>
              </div>
              <span class="external" aria-hidden="true">↗</span>
            </li>
          {/each}
        </ul>
        {#if sourcePage.error}
          <p class="inline-error" role="status">More source records are temporarily unavailable.</p>
        {/if}
        {#if sourcePage.more || sourcePage.error}
          <button class="secondary" onclick={loadSources} disabled={sourcePage.loading}>
            {sourcePage.loading ? "Loading…" : sourcePage.error ? "Try again" : "Load more sources"}
          </button>
        {/if}
      {/if}
    </div>
  </section>
</main>

<style>
  main {
    width: min(100%, 78rem);
    box-sizing: border-box;
    margin-inline: auto;
    padding: 0 clamp(1rem, 4cqw, 3rem) 5rem;
  }
  .masthead {
    min-height: 5.25rem;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1.5rem;
    border-bottom: 1px solid var(--fs-line);
  }
  .brand {
    display: flex;
    align-items: baseline;
    gap: 0.65rem;
    color: var(--fs-ink);
    text-decoration: none;
  }
  .brand strong { font-size: 1rem; letter-spacing: -0.02em; }
  .brand span,
  .catalog-state { color: var(--fs-muted); font-size: 0.78rem; }
  .catalog-state { margin: 0; white-space: nowrap; }
  .catalog-state span {
    display: inline-block;
    width: 0.45rem;
    height: 0.45rem;
    margin-right: 0.4rem;
    border-radius: 50%;
    background: var(--fs-accent);
  }
  .brief {
    display: grid;
    grid-template-columns: minmax(16rem, 0.8fr) minmax(18rem, 1.2fr);
    gap: clamp(2rem, 6cqw, 6rem);
    align-items: end;
    padding: clamp(3rem, 8cqw, 6rem) 0;
  }
  .eyebrow,
  .index,
  .count,
  .source-kind {
    margin: 0;
    color: var(--fs-muted);
    font-size: 0.68rem;
    font-weight: 700;
    letter-spacing: 0.12em;
    text-transform: uppercase;
  }
  h1 {
    max-width: 32rem;
    margin: 0.45rem 0 0;
    font-size: clamp(2rem, 5cqw, 3.15rem);
    line-height: 1.02;
    letter-spacing: -0.045em;
    font-weight: 600;
  }
  .brief > p {
    max-width: 39rem;
    margin: 0;
    color: var(--fs-muted);
    font-size: clamp(1rem, 1.8cqw, 1.15rem);
    line-height: 1.65;
  }
  .register { border-top: 1px solid var(--fs-line-strong); }
  .section-heading {
    display: grid;
    grid-template-columns: 3rem minmax(0, 1fr) auto;
    gap: 1.25rem;
    align-items: start;
    padding: 2rem 0;
  }
  .section-heading h2 {
    margin: 0;
    font-size: 1.45rem;
    line-height: 1.15;
    letter-spacing: -0.025em;
    font-weight: 650;
  }
  .section-heading div > p {
    max-width: 42rem;
    margin: 0.55rem 0 0;
    color: var(--fs-muted);
    line-height: 1.5;
  }
  .count { padding-top: 0.3rem; white-space: nowrap; }
  .message {
    margin: 0;
    padding: 1.5rem 0 3rem 4.25rem;
    border-top: 1px solid var(--fs-line);
    color: var(--fs-muted);
  }
  .action-message { display: flex; justify-content: space-between; align-items: center; gap: 1rem; }
  .action-message p { margin: 0; }
  .profile-list,
  .source-list {
    list-style: none;
    margin: 0;
    padding: 0 0 3rem 4.25rem;
  }
  .profile-list li {
    display: grid;
    grid-template-columns: minmax(0, 0.65fr) minmax(0, 1.35fr) minmax(0, 0.85fr) minmax(8rem, 0.75fr);
    gap: 1.25rem;
    align-items: center;
    min-height: 7.5rem;
    border-top: 1px solid var(--fs-line);
  }
  .profile-status { display: grid; gap: 0.25rem; }
  .profile-status span {
    width: fit-content;
    color: var(--fs-accent);
    font-size: 0.72rem;
    font-weight: 750;
    letter-spacing: 0.08em;
    text-transform: uppercase;
  }
  .profile-status small,
  .profile-identity p,
  dl,
  .source-list p { color: var(--fs-muted); }
  .profile-identity h3 { margin: 0; font-size: 1.05rem; overflow-wrap: anywhere; }
  .profile-identity p { margin: 0.35rem 0 0; font-size: 0.83rem; overflow-wrap: anywhere; }
  dl { display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem; margin: 0; font-size: 0.78rem; }
  dt { font-weight: 700; color: var(--fs-ink); }
  dd { margin: 0.2rem 0 0; overflow-wrap: anywhere; }
  .download { font-size: 0.83rem; font-weight: 700; overflow-wrap: anywhere; }
  .download span { margin-left: 0.35rem; }
  .source-list li {
    display: grid;
    grid-template-columns: 9rem minmax(0, 1fr) auto;
    gap: 1.25rem;
    align-items: center;
    padding: 1.25rem 0;
    border-top: 1px solid var(--fs-line);
  }
  .source-list li > div { min-width: 0; }
  .source-list a { font-size: 1rem; font-weight: 650; overflow-wrap: anywhere; }
  .source-list p { margin: 0.3rem 0 0; font-size: 0.8rem; overflow-wrap: anywhere; }
  .external { color: var(--fs-muted); }
  button {
    border-radius: var(--fs-control-radius);
    padding: 0.72rem 0.95rem;
    font: inherit;
    font-size: 0.82rem;
    font-weight: 700;
    cursor: pointer;
  }
  button:disabled { cursor: wait; opacity: 0.6; }
  .primary { border: 1px solid var(--fs-ink); background: var(--fs-ink); color: white; }
  .secondary { margin: 0 0 3rem 4.25rem; border: 1px solid var(--fs-line-strong); background: transparent; color: var(--fs-ink); }
  .inline-error { margin: -2rem 0 1.25rem 4.25rem; color: var(--fs-danger); }

  @container frameshift-content (width < 52.5em) {
    .brief { grid-template-columns: 1fr; gap: 1.25rem; align-items: start; }
    .profile-list li { grid-template-columns: minmax(0, 0.55fr) minmax(0, 1.2fr) minmax(0, 0.8fr); }
    .download { grid-column: 2 / -1; padding-bottom: 1.25rem; }
  }

  @container frameshift-content (width < 37.5em) {
    main { padding-inline: 1rem; }
    .masthead { min-height: 4.5rem; }
    .brand span { display: none; }
    .catalog-state { white-space: normal; text-align: right; }
    .brief { padding: 2.75rem 0 3.25rem; }
    h1 { font-size: 2.35rem; }
    .section-heading { grid-template-columns: 2rem minmax(0, 1fr); gap: 0.75rem; padding: 1.5rem 0; }
    .count { grid-column: 2; padding: 0; }
    .message,
    .profile-list,
    .source-list { padding-left: 2.75rem; }
    .action-message { align-items: flex-start; flex-direction: column; }
    .profile-list li { grid-template-columns: 1fr; gap: 0.8rem; padding: 1.35rem 0; }
    .profile-status { grid-template-columns: auto 1fr; align-items: baseline; }
    .profile-identity { order: -1; }
    dl { max-width: 18rem; }
    .download { grid-column: auto; padding: 0; }
    .source-list li { grid-template-columns: minmax(0, 1fr) auto; gap: 0.75rem; }
    .source-kind { grid-column: 1 / -1; }
    .secondary { margin-left: 2.75rem; }
    .inline-error { margin-left: 2.75rem; }
  }
</style>
