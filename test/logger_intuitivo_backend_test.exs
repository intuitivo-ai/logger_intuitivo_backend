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
      buffer_size: 8,
      max_buffer_lines: 128,
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
    Logger.configure_backend(@backend, verbose: false)
    # Sync: ensure backend has processed config (send immediate, wait for it)
    Logger.info("HEALTH_CHECK sync")
    assert get_sent(agent, 1000) != [], "backend should be configured"
    # No verbose: short lines stay buffered until byte cap, line cap, or Logger.flush/0
    clear_sent(agent)
    Logger.info("one")
    Logger.info("two")
    assert get_sent(agent, 100) == []
    Logger.info("three")
    Logger.flush()
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

  test "buffer sends batched lines after Logger.flush when under byte and line caps", %{agent: agent} do
    Logger.configure_backend(@backend, verbose: false)
    clear_sent(agent)
    Logger.info("buf1")
    Logger.info("buf2")
    assert get_sent(agent, 100) == []
    Logger.info("buf3")
    Logger.flush()
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

  test "truncation keeps the beginning of the message, not the end", %{agent: agent} do
    # Use a tiny max_message_bytes to force truncation of two combined firmware logs
    long_a = String.duplicate("A", 60)
    long_b = String.duplicate("B", 60)

    Logger.configure_backend(@backend,
      max_message_bytes: 80,
      buffer_size: 8,
      verbose: false
    )
    clear_sent(agent)

    Logger.info("In2Firmware #{long_a}")
    Logger.info("In2Firmware #{long_b}")

    sent = get_sent(agent, 2000)
    assert length(sent) >= 1, "expected at least one sent message"
    {_type, combined} = List.first(sent)

    assert String.contains?(combined, "In2Firmware"),
           "beginning of message should be preserved, got: #{inspect(combined)}"

    assert String.ends_with?(combined, "[truncated]"),
           "expected truncation marker at the end, got: #{inspect(combined)}"

    refute String.contains?(combined, long_b),
           "end content (BBBs) should be truncated, got: #{inspect(combined)}"
  end

  test "flush_buffers preserves chronological order", %{agent: agent} do
    Logger.configure_backend(@backend, buffer_size: 10, max_buffer_lines: 10, verbose: false)
    clear_sent(agent)

    Logger.info("In2Firmware FIRST")
    Logger.info("In2Firmware SECOND")
    Logger.info("In2Firmware THIRD")

    # Logger.flush/0 sends the :flush event to all backends
    Logger.flush()

    sent = get_sent(agent, 2000)
    assert length(sent) >= 1, "expected at least one sent message after flush"
    {_type, combined} = List.first(sent)

    first_pos = :binary.match(combined, "FIRST") |> elem(0)
    second_pos = :binary.match(combined, "SECOND") |> elem(0)
    third_pos = :binary.match(combined, "THIRD") |> elem(0)

    assert first_pos < second_pos,
           "FIRST should appear before SECOND in combined output"

    assert second_pos < third_pos,
           "SECOND should appear before THIRD in combined output"
  end

  test "dedupe_similar_lines keeps one line when timestamps differ", _ do
    a = "2025-05-03 10:00:00.000 [info] In2Firmware ping pid=111"
    b = "2025-05-03 10:00:01.000 [info] In2Firmware ping pid=222"

    out = LoggerIntuitivoBackend.dedupe_similar_lines([b, a])
    assert length(out) == 1
  end

  test "many short lines past buffer_size stay buffered until byte cap or flush", %{agent: agent} do
    Logger.configure_backend(@backend,
      verbose: false,
      buffer_size: 3,
      max_buffer_lines: 500,
      max_message_bytes: 50_000
    )

    clear_sent(agent)
    for i <- 1..20, do: Logger.info("short #{i}")
    assert get_sent(agent, 200) == []
    Logger.flush()
    assert length(get_sent(agent, 2000)) >= 1
  end

  test "verbose off flushes on max_message_bytes before max_buffer_lines", %{agent: agent} do
    Logger.configure_backend(@backend,
      verbose: false,
      buffer_size: 4,
      max_buffer_lines: 50,
      max_message_bytes: 180
    )

    clear_sent(agent)
    # Distinct messages so dedupe does not shrink byte count before the byte threshold.
    for i <- 1..5 do
      Logger.info("In2Firmware " <> String.duplicate("x", 30) <> " u=" <> String.duplicate("a", i))
    end

    sent = get_sent(agent, 3000)
    assert length(sent) >= 1
    {_type, combined} = List.first(sent)
    assert byte_size(combined) <= 180 + 50
    assert combined =~ "In2Firmware"
  end
end
