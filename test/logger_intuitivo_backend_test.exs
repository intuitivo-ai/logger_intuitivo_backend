defmodule LoggerIntuitivoBackendTest do
  use ExUnit.Case, async: false
  require Logger

  @backend {LoggerIntuitivoBackend, :test}

  setup do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    Application.put_env(:logger_intuitivo_backend, :test_agent, agent)
    Logger.add_backend(@backend)

    Logger.configure_backend(@backend,
      socket_module: LoggerIntuitivoBackend.TestSocket,
      level: :info,
      format: "$date $time [$level] $message\n",
      metadata: [],
      verbose_file: Path.join(System.tmp_dir!(), "verbose_#{:erlang.unique_integer([:positive])}.txt"),
      throttle_enabled: true,
      throttle_window_sec: 2,
      throttle_max_repeats: 2,
      buffer_size: 3,
      max_message_bytes: 1024,
      exclude_message_containing: ["SQUASHFS error"],
      immediate_send_containing: ["HEALTH_CHECK"]
    )

    on_exit(fn ->
      Process.sleep(150)
      Logger.remove_backend(@backend)
      Application.delete_env(:logger_intuitivo_backend, :test_agent)
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    %{agent: agent}
  end

  defp get_sent(agent, timeout \\ 500) do
    # Backend runs in Logger process; poll until it has processed
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_sent(agent, deadline)
  end

  defp poll_sent(agent, deadline) do
    list = Agent.get(agent, fn list -> Enum.reverse(list) end)
    if list != [] or System.monotonic_time(:millisecond) >= deadline do
      list
    else
      Process.sleep(10)
      poll_sent(agent, deadline)
    end
  end

  defp clear_sent(agent) do
    Agent.update(agent, fn _ -> [] end)
  end

  test "init and configure verbose", %{agent: agent} do
    # Sync: ensure backend has processed config (send immediate, wait for it)
    Logger.info("HEALTH_CHECK sync")
    assert get_sent(agent, 1000) != [], "backend should be configured"
    # Default: no verbose, so logs are buffered until buffer_size
    clear_sent(agent)
    Logger.info("one")
    Logger.info("two")
    assert get_sent(agent, 100) == []
    Logger.info("three")
    # Buffer of 3 reached for system logs; allow time for backend to flush
    sent = get_sent(agent, 2000)
    assert length(sent) >= 1, "expected at least one sent message, got: #{inspect(sent)}"
  end

  test "verbose mode sends each log immediately", %{agent: agent} do
    Logger.configure_backend(@backend, verbose: true)
    clear_sent(agent)
    Logger.info("In2Firmware immediate")
    assert [{:log, msg} | _] = get_sent(agent)
    assert msg =~ "immediate"
    Logger.configure_backend(@backend, verbose: false)
  end

  test "excluded message (SQUASHFS error) is not sent", %{agent: agent} do
    clear_sent(agent)
    Logger.info("Something with SQUASHFS error inside")
    # Should not appear in any send
    sent = get_sent(agent)
    refute Enum.any?(sent, fn
             {_, m} -> String.contains?(m, "SQUASHFS")
           end)
  end

  test "immediate_send_containing sends health check at once", %{agent: agent} do
    clear_sent(agent)
    Logger.info("HEALTH_CHECK ping")
    sent = get_sent(agent)
    assert length(sent) == 1
    assert [{:log, msg} | _] = sent
    assert msg =~ "HEALTH_CHECK"
  end

  test "buffer flushes when buffer_size reached", %{agent: agent} do
    Logger.configure_backend(@backend, verbose: false)
    clear_sent(agent)
    Logger.info("buf1")
    Logger.info("buf2")
    assert get_sent(agent, 100) == []
    Logger.info("buf3")
    sent = get_sent(agent, 2000)
    assert length(sent) >= 1, "expected at least one sent message, got: #{inspect(sent)}"
    # Combined message should contain the three lines
    {_type, combined} = List.first(sent)
    assert combined =~ "buf1"
    assert combined =~ "buf2"
    assert combined =~ "buf3"
  end

  test "throttle: repeated message is limited", %{agent: agent} do
    Logger.configure_backend(@backend, verbose: true, throttle_max_repeats: 2)
    clear_sent(agent)
    Logger.info("Same message")
    Logger.info("Same message")
    Logger.info("Same message")
    Logger.info("Same message")
    sent = get_sent(agent)
    # First 2 should be sent, then throttled
    same = Enum.filter(sent, fn {_, m} -> m =~ "Same message" and not String.starts_with?(m, "[throttled]") end)
    assert length(same) <= 2
  end

  test "format includes level and message", %{agent: agent} do
    Logger.configure_backend(@backend, verbose: true)
    Logger.info("HEALTH_CHECK sync")
    assert get_sent(agent, 1000) != []
    clear_sent(agent)
    Logger.info("formatted")
    sent = get_sent(agent, 1500)
    assert [{_type, msg} | _] = sent, "expected at least one sent message, got: #{inspect(sent)}"
    assert msg =~ "info"
    assert msg =~ "formatted"
  end
end
