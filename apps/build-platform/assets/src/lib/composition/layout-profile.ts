export const layoutProfileThresholds = {
  compactUpperBound: 600,
  mediumUpperBound: 840,
} as const

export type LayoutProfile = "compact" | "medium" | "expanded"

export function layoutProfileForWidth(width: number, fontSize = 16): LayoutProfile {
  const textScale = fontSize / 16
  if (width < layoutProfileThresholds.compactUpperBound * textScale) return "compact"
  if (width < layoutProfileThresholds.mediumUpperBound * textScale) return "medium"
  return "expanded"
}
