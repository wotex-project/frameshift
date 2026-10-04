defmodule Frameshift do
  @moduledoc """
  Defines the shared identity types and ownership of the native artwork core.

  The OTP application owns durable masters, canonical recipes, rendered artifact
  relationships, paired-frame records and protocol orchestration. Content uses
  SHA-256 identities; mutable display state and delivery receipts retain separate
  revisions. `Frameshift.Library` serializes metadata changes and
  `Frameshift.ContentStore` retains immutable payloads outside SQLite.

  ## Integration boundaries

  The Swift shell owns presentation, image decoding and Apple APIs. The supervised
  Zig worker owns raster transforms through `Frameshift.Renderer`; frames own
  verified persistence and physical asset activation. Network acceptance does
  not imply display completion. The companion composition platform has a separate
  application/database and cannot control this local core by knowing an identity.

  Start through `Frameshift.Application` for the configured supervision tree.
  Local clients use `Frameshift.LocalAPI` through authenticated IPC rather than
  opening the SQLite database or passing raw renderer/platform handles.
  """

  @type digest :: String.t()
  @type frame_id :: String.t()
  @type profile_id :: String.t()
end
