defmodule FrameshiftBuild.ConjunctAdapter do
  @moduledoc """
  Exact v1 value and placement conversions for the Conjunct product adapter.

  These primitives do not validate whole profiles, create artifacts or grant
  physical acceptance. The owning mapper retains the resolved original inputs,
  source evidence, native IDs and complete migration report.

  `v1_inputs/5` prepares that mapper's complete retained original closure through
  the existing v1 codecs. It verifies all five identity domains, refuses missing
  profiles and checks exact compilation-context bytes without emitting successors.
  """

  @scopes %{
    "component" => :component,
    "power" => :power_port,
    "signal" => :signal_port,
    "mechanical" => :mechanical_port
  }
  @units %{
    "um" => {"length", "m", 1_000_000, 0, 5_000_000},
    "mv" => {"voltage", "V", 1_000, 0, 300_000},
    "ma" => {"current", "A", 1_000, 0, 100_000},
    "mw" => {"power", "W", 1_000, 0, 1_000_000},
    "g" => {"mass", "kg", 1_000, 0, 100_000},
    "ms" => {"duration", "s", 1_000, 0, 604_800_000},
    "count" => {"count", "1", 1, 0, 1_000_000},
    "byte" => {"count", "1", 1, 0, 1_099_511_627_776}
  }
  @rotations %{
    0 => [1, 0, 0, 0, 1, 0, 0, 0, 1],
    90 => [0, 1, 0, -1, 0, 0, 0, 0, 1],
    180 => [-1, 0, 0, 0, -1, 0, 0, 0, 1],
    270 => [0, -1, 0, 1, 0, 0, 0, 0, 1]
  }

  @doc "Retains a complete exact v1 closure for a later explicit successor mapping."
  @spec v1_inputs(term(), term(), term(), term(), term()) :: {:ok, map()} | {:error, binary()}
  defdelegate v1_inputs(assembly, profiles, mappings, layouts, context),
    to: FrameshiftBuild.ConjunctInputs,
    as: :import

  @doc "Converts one registered v1 numeric property to a canonical inclusive interval."
  @spec quantity(term(), term(), term(), term(), term()) :: {:ok, map()} | {:error, binary()}
  def quantity(scope, key, unit, lower, upper)
      when is_binary(scope) and is_binary(key) and is_binary(unit) and is_integer(lower) and
             is_integer(upper) do
    with {:ok, owner} <- scope(scope),
         {:ok, minimum} <- property(owner, key, unit),
         {:ok, {kind, target, denominator, offset, maximum}} <- conversion(key, unit),
         :ok <- range(lower, upper, minimum, maximum) do
      value = fn bound ->
        %{
          "quantity_kind" => kind,
          "unit" => target,
          "value" => rational(bound + offset, denominator)
        }
      end

      {:ok, %{"type" => "interval", "lower" => value.(lower), "upper" => value.(upper)}}
    end
  end

  def quantity(_, _, _, _, _), do: {:error, "invalid_document"}

  @doc "Converts the rotated v1 bare-outline origin to an exact Conjunct rigid transform."
  @spec transform(term(), term(), term(), term()) :: {:ok, map()} | {:error, binary()}
  def transform(rotation, position, width, height) do
    with :ok <- placement(rotation, position),
         :ok <- dimension(width),
         :ok <- dimension(height),
         {:ok, offset} <- offset(rotation, width, height) do
      [x, y, z] = Enum.zip_with(position, offset, &+/2)

      {:ok,
       %{
         "rotation" => Enum.map(Map.fetch!(@rotations, rotation), &rational(&1, 1)),
         "translation" => Enum.map([x, -y, -z], &rational(&1, 1_000_000))
       }}
    end
  end

  @doc "Creates a bounded successor local ID while the caller preserves the native identifier."
  @spec local_id(term(), term()) :: {:ok, binary()} | {:error, binary()}
  def local_id(kind, native_id) do
    if identifier?(kind) and identifier?(native_id) do
      payload = "frameshift.conjunct.local.v1\0" <> kind <> "\0" <> native_id
      {:ok, "v1-" <> Base.encode16(:crypto.hash(:sha256, payload), case: :lower)}
    else
      {:error, "invalid_identifier"}
    end
  rescue
    _ -> {:error, "crypto_unavailable"}
  catch
    _, _ -> {:error, "crypto_unavailable"}
  end

  defp scope(scope) do
    case Map.fetch(@scopes, scope) do
      {:ok, owner} -> {:ok, owner}
      :error -> {:error, "invalid_document"}
    end
  end

  defp property(scope, key, unit) do
    case :frameshift_build@compiler@properties.lookup(scope, key) do
      {:ok, {:number, ^unit, minimum}} -> {:ok, minimum}
      {:ok, {:number, _, _}} -> {:error, "invalid_unit"}
      _ -> {:error, "unsupported_property"}
    end
  end

  defp conversion(key, "mc") do
    case key do
      "temperature.ambient_rise" -> {:ok, {"temperature-difference", "K", 1_000, 0, 300_000}}
      _ -> {:ok, {"temperature", "K", 1_000, 273_150, 300_000}}
    end
  end

  defp conversion(_, unit) do
    case Map.fetch(@units, unit) do
      {:ok, conversion} -> {:ok, conversion}
      :error -> {:error, "invalid_unit"}
    end
  end

  defp range(lower, upper, minimum, maximum) do
    if lower >= minimum and upper <= maximum and lower <= upper,
      do: :ok,
      else: {:error, "invalid_range"}
  end

  defp placement(rotation, [x, y, z])
       when is_integer(rotation) and is_integer(x) and is_integer(y) and is_integer(z) do
    if Map.has_key?(@rotations, rotation) and Enum.all?([x, y, z], &(&1 in 0..5_000_000)),
      do: :ok,
      else: {:error, "invalid_range"}
  end

  defp placement(_, _), do: {:error, "invalid_document"}
  defp dimension(nil), do: :ok

  defp dimension([lower, upper]) when is_integer(lower) and is_integer(upper),
    do: range(lower, upper, 1, 5_000_000)

  defp dimension(_), do: {:error, "invalid_document"}

  defp offset(rotation, width, height) do
    with {:ok, x} <- needed(rotation in [90, 180], height),
         {:ok, y} <- needed(rotation in [180, 270], width) do
      case rotation do
        0 -> {:ok, [0, 0, 0]}
        90 -> {:ok, [x, 0, 0]}
        180 -> {:ok, [y, x, 0]}
        270 -> {:ok, [0, y, 0]}
      end
    end
  end

  defp needed(false, _), do: {:ok, 0}
  defp needed(true, [value, value]), do: {:ok, value}
  defp needed(true, _), do: {:error, "unknown_geometry"}

  defp rational(numerator, denominator) do
    divisor = Integer.gcd(numerator, denominator)

    %{
      "n" => Integer.to_string(div(numerator, divisor)),
      "d" => Integer.to_string(div(denominator, divisor))
    }
  end

  defp identifier?(value) when is_binary(value),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._+\-]{0,95}\z/, value)

  defp identifier?(_), do: false
end
