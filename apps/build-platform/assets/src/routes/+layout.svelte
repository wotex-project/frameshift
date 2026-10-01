<script lang="ts">
import "../app.css"
import AdaptiveContent from "$lib/composition/AdaptiveContent.svelte"

let { children } = $props()
</script>

<AdaptiveContent>
  {@render children()}
</AdaptiveContent>
