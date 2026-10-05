defmodule FrameshiftPlatform.Access.Authentication do
  @moduledoc """
  Adapts the admitted Ash Authentication account and token actions for the host.

  `register/1` provisions a private account from exactly `:email`, `:password`
  and `:password_confirmation`; `sign_in/1` accepts exactly `:email` and
  `:password`. Keys are atoms at this internal boundary. Email identifiers are
  bounded to 254 UTF-8 bytes. Passwords preserve every code point and byte,
  including surrounding whitespace, with no trimming or silent truncation.
  Registration requires 15–128 code points and matching confirmation.

  ## Results and privacy

  Successful credential actions return the upstream
  `FrameshiftPlatform.Access.User` record. Its sensitive fields and token metadata
  are transient host inputs, never a JSON response or diagnostic value. Invalid
  parameters return `:invalid_input`; rejected credentials return
  `:invalid_credentials`; missing configuration or exceptional storage failure
  returns `:unavailable`. The upstream session verifier also treats storage
  refusal as invalid credentials, always without granting access. An exceptional
  registration returns `:outcome_unknown`, since
  the caller must not assume that persistent work did not occur or retry it.
  No raw upstream exception, password, token or email enters an error result.

  ## Current account and revocation

  `authenticate/1` bounds the opaque token and uses the upstream session consumer
  to verify signature, expiry, stored-token presence and current account. It
  returns the current account or a finite refusal. `revoke/1` delegates to the
  verified upstream token-resource operation; a failed operation cannot report
  completed logout. These functions perform no retry, provider switch or role
  inference. The HTTP owner must add cookie, CSRF, origin and work-budget controls
  before exposing a password route or deriving a command permission context.
  """

  alias AshAuthentication.{Info, Strategy}
  alias FrameshiftPlatform.Access.{Token, User}

  @type failure ::
          :invalid_input | :invalid_credentials | :unavailable | :outcome_unknown

  @doc "Provisions a password account through the upstream authentication interaction."
  @spec register(map()) :: {:ok, User.t()} | {:error, failure()}
  def register(params) do
    with :ok <- parameters(params, [:email, :password, :password_confirmation], 15),
         :ok <- signer() do
      credential_action(:register, params)
    end
  rescue
    _ -> {:error, :outcome_unknown}
  end

  @doc "Checks bounded credentials without exposing account lookup or failure details."
  @spec sign_in(map()) :: {:ok, User.t()} | {:error, failure()}
  def sign_in(params) do
    with :ok <- parameters(params, [:email, :password], 1),
         :ok <- signer() do
      credential_action(:sign_in, params)
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Resolves a current account only from a verified, present, unexpired token."
  @spec authenticate(binary()) :: {:ok, User.t()} | {:error, failure()}
  def authenticate(token) do
    with :ok <- token_input(token), :ok <- signer() do
      case AshAuthentication.Plug.Helpers.authenticate_resource_from_session(
             User,
             %{"user_token" => token},
             :frameshift_platform,
             []
           ) do
        {:ok, %User{} = user} -> {:ok, user}
        _ -> {:error, :invalid_credentials}
      end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Revokes an admitted token through the upstream verified-token boundary."
  @spec revoke(binary()) :: :ok | {:error, failure()}
  def revoke(token) do
    with :ok <- token_input(token),
         :ok <- signer(),
         {:ok, _, User} <- AshAuthentication.Jwt.verify(token, User) do
      case AshAuthentication.TokenResource.Actions.revoke(Token, token) do
        :ok -> :ok
        {:error, %Ash.Error.Invalid{}} -> {:error, :invalid_credentials}
        _ -> {:error, :unavailable}
      end
    else
      :error -> {:error, :invalid_credentials}
      error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp credential_action(action, params) do
    with {:ok, strategy} <- Info.strategy(User, :password),
         {:ok, %User{} = user} <- Strategy.action(strategy, action, params, []) do
      {:ok, user}
    else
      {:error, %AshAuthentication.Errors.AuthenticationFailed{caused_by: %Ash.Error.Unknown{}}} ->
        {:error, :unavailable}

      {:error, %AshAuthentication.Errors.AuthenticationFailed{}} ->
        {:error, :invalid_credentials}

      {:error, %Ash.Error.Invalid{}} ->
        {:error, :invalid_credentials}

      _ ->
        {:error, :unavailable}
    end
  end

  defp signer do
    case Application.fetch_env(:frameshift_platform, :authentication_signing_secret) do
      {:ok, key} when is_binary(key) and byte_size(key) >= 32 -> :ok
      _ -> {:error, :unavailable}
    end
  end

  defp parameters(params, keys, minimum) when is_map(params) do
    if Enum.sort(Map.keys(params)) == Enum.sort(keys) and
         text?(params.email, 1, 254) and byte_size(params.email) <= 254 and
         Enum.all?(keys -- [:email], &text?(Map.fetch!(params, &1), minimum, 128)) do
      :ok
    else
      {:error, :invalid_input}
    end
  end

  defp parameters(_, _, _), do: {:error, :invalid_input}

  defp text?(value, minimum, maximum) when is_binary(value) and byte_size(value) <= 512,
    do: String.valid?(value) and String.length(value) in minimum..maximum

  defp text?(_, _, _), do: false

  defp token_input(token) when is_binary(token) and byte_size(token) in 1..4096,
    do: :ok

  defp token_input(_), do: {:error, :invalid_input}
end
