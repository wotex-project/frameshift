<script lang="ts">
import { onMount } from "svelte"
import { type LayoutProfile, layoutProfileForWidth } from "./layout-profile"

let { children } = $props()
let root: HTMLElement
let profile = $state<LayoutProfile>("compact")

onMount(() => {
  const observer = new ResizeObserver(([entry]) => {
    if (entry) {
      const fontSize = Number.parseFloat(getComputedStyle(root).fontSize)
      profile = layoutProfileForWidth(entry.contentRect.width, fontSize)
    }
  })

  observer.observe(root)
  return () => observer.disconnect()
})
</script>

<div class="adaptive-content" data-layout-profile={profile} bind:this={root}>
  {@render children()}
</div>
