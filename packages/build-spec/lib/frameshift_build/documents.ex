defmodule FrameshiftBuild.Documents do
  @moduledoc """
  Admits document lists and translates shared Gleam results for Elixir adapters.

  `input_types/1` requires binary documents and bounds each list to 64 entries.
  `hash/2` applies the supplied identity function to every exact byte document,
  returns digest/byte pairs and stops at the first refusal. Full byte-budget and
  reference checks remain with the relevant resolution owner.

  ## Result vocabulary

  `normalize/1` preserves successful values and maps a typed Gleam refusal to its
  stable binary code. It does not rescue arbitrary programming exceptions or
  invent a successful fallback for unrecognized content.

  `FrameshiftBuild.Context` and `FrameshiftBuild.Resolution` reuse these helpers
  before shared-codec resolution. Hashing a document establishes identity only;
  source claims and physical/current-use admission retain separate owners.
  """

  @spec input_types(term()) :: :ok | {:error, binary()}
  def input_types(documents) when length(documents) <= 64 do
    if Enum.all?(documents, &is_binary/1), do: :ok, else: {:error, "invalid_document"}
  end

  def input_types(documents) when length(documents) > 64, do: {:error, "invalid_count"}
  def input_types(_), do: {:error, "invalid_document"}

  @spec hash([binary()], (binary() -> {:ok, binary()} | {:error, binary()})) ::
          {:ok, [{binary(), binary()}]} | {:error, binary()}
  def hash(documents, identity) do
    Enum.reduce_while(documents, {:ok, []}, fn bytes, {:ok, acc} ->
      case identity.(bytes) do
        {:ok, pin} -> {:cont, {:ok, [{pin, bytes} | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @spec normalize({:ok, term()} | {:error, term()}) :: {:ok, term()} | {:error, binary()}
  def normalize({:ok, value}), do: {:ok, value}
  def normalize({:error, error}), do: {:error, :frameshift_build.refusal_code(error)}
end
