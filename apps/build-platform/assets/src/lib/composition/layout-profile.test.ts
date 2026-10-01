import assert from "node:assert/strict"
import test from "node:test"

import { layoutProfileForWidth } from "./layout-profile.ts"

test("maps exact and fractional allocation boundaries", () => {
  assert.equal(layoutProfileForWidth(0), "compact")
  assert.equal(layoutProfileForWidth(599.5), "compact")
  assert.equal(layoutProfileForWidth(600), "medium")
  assert.equal(layoutProfileForWidth(839.5), "medium")
  assert.equal(layoutProfileForWidth(840), "expanded")
  assert.equal(layoutProfileForWidth(1_280), "expanded")
})

test("preserves space for enlarged text", () => {
  assert.equal(layoutProfileForWidth(640, 32), "compact")
  assert.equal(layoutProfileForWidth(1_199, 32), "compact")
  assert.equal(layoutProfileForWidth(1_200, 32), "medium")
  assert.equal(layoutProfileForWidth(1_679, 32), "medium")
  assert.equal(layoutProfileForWidth(1_680, 32), "expanded")
})
