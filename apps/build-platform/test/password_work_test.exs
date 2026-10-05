defmodule FrameshiftPlatform.PasswordWorkTest do
  @moduledoc false

  use FrameshiftPlatform.DataCase, async: false
  alias FrameshiftPlatform.Access.{Authentication, PasswordWork}
  alias FrameshiftPlatform.Repo

  setup do
    tasks = start_supervised!({Task.Supervisor, name: __MODULE__.PasswordTasks, max_children: 2})
    options = [name: __MODULE__.Limiter, task_supervisor: __MODULE__.PasswordTasks]
    limiter = start_supervised!({PasswordWork, options})
    on_exit(fn -> :persistent_term.erase({PasswordWork, __MODULE__.PasswordTasks}) end)
    %{tasks: tasks, limiter: limiter, options: options}
  end

  test "IP and total windows refuse without starting more workers", %{
    tasks: tasks,
    limiter: limiter
  } do
    for _ <- 1..6 do
      assert {:error, :invalid_input} = attempt(limiter, {127, 0, 0, 1}, %{})
      await_empty(tasks)
    end

    assert {:error, :limited} = attempt(limiter, {127, 0, 0, 1}, %{})

    for number <- 2..55 do
      assert {:error, :invalid_input} = attempt(limiter, {127, 0, 0, number}, %{})
      await_empty(tasks)
    end

    assert {:error, :limited} = attempt(limiter, {127, 0, 0, 56}, %{})
    assert Task.Supervisor.children(tasks) == []
  end

  test "limiter restart cannot reopen lost attempt state", %{limiter: limiter, options: options} do
    assert {:error, :invalid_input} = attempt(limiter, {127, 0, 0, 1}, %{})
    stop_supervised!(PasswordWork)
    restarted = start_supervised!({PasswordWork, options})
    assert {:error, :unavailable} = attempt(restarted, {127, 0, 0, 2}, %{})
  end

  test "worker-supervisor loss closes admission", %{tasks: tasks, limiter: limiter} do
    monitor = Process.monitor(tasks)
    stop_supervised!(__MODULE__.PasswordTasks)
    assert_receive {:DOWN, ^monitor, :process, ^tasks, _}

    replacement =
      start_supervised!({Task.Supervisor, name: __MODULE__.PasswordTasks, max_children: 2})

    refute replacement == tasks
    assert {:error, :unavailable} = attempt(limiter, {127, 0, 0, 1}, %{})
  end

  @tag timeout: 90_000
  test "disconnected callers and window renewal retain actual workers until exit", %{
    tasks: tasks,
    limiter: limiter
  } do
    password = "a bounded native password 🔒"
    email = "work-#{Ecto.UUID.generate()}@example.com"

    assert {:ok, _} =
             Authentication.register(%{
               email: email,
               password: password,
               password_confirmation: password
             })

    for number <- 1..58 do
      assert {:error, :invalid_input} = attempt(limiter, {127, 2, 0, number}, %{})
      await_empty(tasks)
    end

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:frameshift_platform, :repo, :query],
        &__MODULE__.pause_read/4,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler)

      if Process.alive?(tasks),
        do: Enum.each(Task.Supervisor.children(tasks), &send(&1, :release_password_work))
    end)

    try do
      owner = self()
      first = caller(owner, limiter, 100, %{email: email, password: password})
      assert_receive {:password_read, worker_one}, 5000
      _ = caller(owner, limiter, 101, %{email: email, password: password})
      assert_receive {:password_read, worker_two}, 5000
      assert length(Task.Supervisor.children(tasks)) == 2
      Process.exit(first, :kill)

      assert {:error, :limited} =
               attempt(limiter, {127, 2, 0, 102}, %{email: email, password: password})

      # Exercise the declared real monotonic window while both admitted tasks remain alive.
      Process.sleep(60_100)

      assert {:error, :limited} =
               attempt(limiter, {127, 2, 0, 102}, %{email: email, password: password})

      :telemetry.detach(handler)
      send(worker_one, :release_password_work)
      send(worker_two, :release_password_work)
      assert_receive {:completed, 101, :ok}, 5000
      await_empty(tasks)
      assert {:ok, _} = attempt(limiter, {127, 2, 0, 102}, %{email: email, password: password})
      await_empty(tasks)
      assert %{rows: [[4]]} = Repo.query!("SELECT count(*) FROM platform_tokens", [])
    after
      :telemetry.detach(handler)
      Enum.each(Task.Supervisor.children(tasks), &send(&1, :release_password_work))
    end
  end

  test "abnormal admitted worker exit fences remaining native work", %{
    tasks: tasks,
    limiter: limiter
  } do
    password = "a bounded native password 🔒"
    email = "work-#{Ecto.UUID.generate()}@example.com"

    assert {:ok, _} =
             Authentication.register(%{
               email: email,
               password: password,
               password_confirmation: password
             })

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:frameshift_platform, :repo, :query],
        &__MODULE__.pause_read/4,
        self()
      )

    try do
      _ = caller(self(), limiter, 1, %{email: email, password: password})
      assert_receive {:password_read, worker}, 5000
      Process.exit(worker, :kill)
      assert_receive {:completed, 1, {:error, :unavailable}}, 5000
      await_empty(tasks)

      assert {:error, :unavailable} =
               attempt(limiter, {127, 2, 0, 2}, %{email: email, password: password})
    after
      :telemetry.detach(handler)
      Enum.each(Task.Supervisor.children(tasks), &send(&1, :release_password_work))
    end
  end

  @spec pause_read([atom()], map(), map(), pid()) :: :ok | nil
  def pause_read(_, _, %{query: query}, owner) do
    if String.starts_with?(query, "SELECT") and String.contains?(query, "platform_users") do
      send(owner, {:password_read, self()})

      receive do
        :release_password_work -> :ok
      after
        80_000 -> :ok
      end
    end
  end

  defp caller(owner, limiter, number, params) do
    spawn(fn ->
      result =
        case attempt(limiter, {127, 2, 0, number}, params) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      send(owner, {:completed, number, result})
    end)
  end

  defp attempt(limiter, ip, params),
    do: GenServer.call(limiter, {:sign_in, ip, params}, :infinity)

  defp await_empty(tasks), do: await_empty(tasks, System.monotonic_time(:millisecond) + 5000)

  defp await_empty(tasks, deadline) do
    if Task.Supervisor.children(tasks) != [] do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(5)
      await_empty(tasks, deadline)
    end
  end
end
