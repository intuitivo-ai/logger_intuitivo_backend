# Copyright 2015 Marcelo Gornstein <marcelog@gmail.com>
# Adapted for Intuitivo firmware sockets (CloudWatch, throttle, verbose, buffers).
# Licensed under the Apache License, Version 2.0.
defmodule LoggerIntuitivoBackend do
  @moduledoc """
  Logger backend that sends logs through the firmware Socket (e.g. to CloudWatch).
  Supports verbose mode, buffering with size limit, throttling of repeated messages,
  and configurable filters (exclude SQUASHFS, immediate health check).
  """
  @behaviour :gen_event

  @default_format "$date $time [$level] $metadata $message\n"
  @default_buffer_size 8
  @default_max_message_bytes 8 * 1024
  @default_throttle_window_ms 60_000
  @default_throttle_max_repeats 3
  @default_verbose_file "/root/verbose.txt"
  @default_exclude_containing ["SQUASHFS error"]
  @default_immediate_containing ["MAIN_SERVICES_CONNECTIONS_SOCKET_HEALTH"]
  @firmware_marker "In2Firmware"
  @throttle_summary_prefix "[throttled]"

  def init({__MODULE__, name}) do
    state = configure(name, [])
    verbose = read_verbose(state.verbose_file)
    {:ok,
     state
     |> Map.put(:buffer_logs_firmware, [])
     |> Map.put(:buffer_logs_system, [])
     |> Map.put(:verbose, verbose)
     |> Map.put(:throttle_map, %{})}
  end

  def handle_call({:configure, [verbose: verbose]}, %{verbose_file: verbose_file} = state) do
    write_verbose(verbose_file, verbose)
    {:ok, :ok, %{state | verbose: verbose}}
  end

  def handle_call({:configure, opts}, %{name: name} = state) do
    {:ok, :ok, configure(name, opts, state)}
  end

  def handle_info(_, state), do: {:ok, state}

  def handle_event(:flush, state), do: {:ok, flush_buffers(state)}

  def handle_event(
        {level, _gl, {Logger, msg, ts, md}},
        %{level: min_level, metadata_filter: metadata_filter, metadata_reject: metadata_reject} = state
      ) do
    if (is_nil(min_level) or Logger.compare_levels(level, min_level) != :lt) and
         metadata_matches?(md, metadata_filter) and
         (is_nil(metadata_reject) or !metadata_matches?(md, metadata_reject)) do
      log_event(level, msg, ts, md, state)
    else
      {:ok, state}
    end
  end

  def code_change(_old_vsn, state, _extra), do: {:ok, state}
  def terminate(_reason, _state), do: :ok

  # --- Helpers ---

  defp random_id do
    :crypto.strong_rand_bytes(5) |> Base.url_encode64(padding: false)
  end

  defp read_verbose(verbose_file) do
    case File.read(verbose_file) do
      {:ok, content} -> String.trim(content) == "true"
      {:error, _} -> false
    end
  end

  defp write_verbose(verbose_file, verbose) do
    File.write(verbose_file, to_string(verbose))
  end

  defp log_event(level, msg, ts, md, state) do
    output = format_event(level, msg, ts, md, state)

    if excluded?(output, state.exclude_message_containing) do
      {:ok, state}
    else
      state_after_throttle = expire_throttle(state)
      {should_send, state_after_throttle} = throttle_check(output, state_after_throttle)

      if should_send do
        do_send(output, state_after_throttle)
      else
        {:ok, state_after_throttle}
      end
    end
  end

  defp excluded?(output, list) when is_list(list) do
    Enum.any?(list, &String.contains?(output, &1))
  end
  defp excluded?(_, _), do: false

  defp immediate_send?(output, list) when is_list(list) do
    Enum.any?(list, &String.contains?(output, &1))
  end
  defp immediate_send?(_, _), do: false

  defp throttle_summary?(output), do: String.starts_with?(output, @throttle_summary_prefix)

  defp expire_throttle(state) do
    %{throttle_map: throttle_map, throttle_window_ms: window_ms} = state

    now = :os.system_time(:millisecond)
    expired_keys =
      throttle_map
      |> Enum.filter(fn {_k, {_count, first_ts, _msg}} -> now - first_ts > window_ms end)
      |> Enum.map(&elem(&1, 0))

    %{state | throttle_map: Map.drop(throttle_map, expired_keys)}
  end

  defp throttle_check(output, state) do
    %{
      throttle_enabled: enabled,
      throttle_map: throttle_map,
      throttle_max_repeats: max_repeats
    } = state

    if not enabled or throttle_summary?(output) do
      {:true, state}
    else
      key = output
      now = :os.system_time(:millisecond)

      {count, first_ts, _} =
        case Map.get(throttle_map, key) do
          nil -> {1, now, output}
          {c, ft, _} -> {c + 1, ft, output}
        end

      new_map = Map.put(throttle_map, key, {count, first_ts, output})
      state = %{state | throttle_map: new_map}
      should_send = count <= max_repeats
      {should_send, state}
    end
  end

  defp do_send(output, state) do
    %{
      verbose: verbose,
      buffer_logs_firmware: buf_fw,
      buffer_logs_system: buf_sys,
      socket_module: socket_module,
      immediate_send_containing: immediate_list
    } = state

    if is_nil(socket_module) do
      {:ok, state}
    else
      immediate = immediate_send?(output, immediate_list)
      firmware_log? = String.contains?(output, @firmware_marker)

      cond do
        immediate ->
          socket_module.send_log({output, random_id()})
          {:ok, state}

        verbose ->
          if firmware_log? do
            socket_module.send_log({output, random_id()})
          else
            send_system(socket_module, output)
          end
          {:ok, state}

        firmware_log? ->
          new_buf = [output | buf_fw]
          state = maybe_flush_firmware_buffer(new_buf, state)
          {:ok, state}

        true ->
          new_buf = [output | buf_sys]
          state = maybe_flush_system_buffer(new_buf, state)
          {:ok, state}
      end
    end
  end

  defp maybe_flush_firmware_buffer(new_buf, state) do
    %{buffer_size: max_len, max_message_bytes: max_bytes, socket_module: socket_module} = state
    if length(new_buf) >= max_len and not is_nil(socket_module) do
      combined = combine_and_truncate(new_buf, max_bytes)
      socket_module.send_log({combined, random_id()})
      %{state | buffer_logs_firmware: []}
    else
      %{state | buffer_logs_firmware: new_buf}
    end
  end

  defp maybe_flush_system_buffer(new_buf, state) do
    %{buffer_size: max_len, max_message_bytes: max_bytes, socket_module: socket_module} = state
    if length(new_buf) >= max_len and not is_nil(socket_module) do
      combined = combine_and_truncate(new_buf, max_bytes)
      send_system(socket_module, combined)
      %{state | buffer_logs_system: []}
    else
      %{state | buffer_logs_system: new_buf}
    end
  end

  defp combine_and_truncate(lines, max_bytes) do
    combined =
      lines
      |> Enum.reverse()
      |> Enum.join("\n")

    if byte_size(combined) <= max_bytes do
      combined
    else
      suffix = "\n... [truncated]"
      keep = max_bytes - byte_size(suffix)
      <<_::binary-size(byte_size(combined) - keep), rest::binary>> = combined
      rest <> suffix
    end
  end

  defp send_system(socket_module, msg) do
    if function_exported?(socket_module, :send_system, 1) do
      socket_module.send_system(msg)
    end
  end

  defp flush_buffers(state) do
    %{
      buffer_logs_firmware: buf_fw,
      buffer_logs_system: buf_sys,
      max_message_bytes: max_bytes,
      socket_module: socket_module
    } = state

    state = %{state | buffer_logs_firmware: [], buffer_logs_system: []}

    if not is_nil(socket_module) do
      if buf_fw != [] do
        combined = combine_and_truncate(Enum.reverse(buf_fw), max_bytes)
        socket_module.send_log({combined, random_id()})
      end

      if buf_sys != [] do
        combined = combine_and_truncate(Enum.reverse(buf_sys), max_bytes)
        send_system(socket_module, combined)
      end
    end

    state
  end

  defp format_event(level, msg, ts, md, %{format: format, metadata: keys}) do
    IO.chardata_to_string(
      Logger.Formatter.format(format, level, msg, ts, take_metadata(md, keys))
    )
  end

  defp take_metadata(metadata, :all), do: metadata
  defp take_metadata(metadata, keys) do
    Enum.reduce(keys, [], fn key, acc ->
      case Keyword.fetch(metadata, key) do
        {:ok, val} -> [{key, val} | acc]
        :error -> acc
      end
    end)
    |> Enum.reverse()
  end

  def metadata_matches?(_md, nil), do: true
  def metadata_matches?(_md, []), do: true
  def metadata_matches?(md, [{key, [_ | _] = val} | rest]) do
    case Keyword.fetch(md, key) do
      {:ok, md_val} -> md_val in val and metadata_matches?(md, rest)
      _ -> false
    end
  end
  def metadata_matches?(md, [{key, val} | rest]) do
    case Keyword.fetch(md, key) do
      {:ok, ^val} -> metadata_matches?(md, rest)
      _ -> false
    end
  end

  defp configure(name, opts), do: configure(name, opts, default_state())

  defp default_state do
    %{
      name: nil,
      format: nil,
      level: nil,
      metadata: nil,
      metadata_filter: nil,
      metadata_reject: nil,
      buffer_logs_firmware: [],
      buffer_logs_system: [],
      buffer_size: @default_buffer_size,
      max_message_bytes: @default_max_message_bytes,
      throttle_enabled: true,
      throttle_window_ms: @default_throttle_window_ms,
      throttle_max_repeats: @default_throttle_max_repeats,
      throttle_map: %{},
      verbose_file: @default_verbose_file,
      exclude_message_containing: @default_exclude_containing,
      immediate_send_containing: @default_immediate_containing,
      socket_module: nil,
      verbose: false
    }
  end

  defp configure(name, opts, state) do
    env = Application.get_env(:logger, name, [])
    opts = Keyword.merge(env, opts)
    Application.put_env(:logger, name, opts)

    level = Keyword.get(opts, :level)
    metadata = Keyword.get(opts, :metadata, [])
    format_opts = Keyword.get(opts, :format, @default_format)
    format = Logger.Formatter.compile(format_opts)
    metadata_filter = Keyword.get(opts, :metadata_filter)
    metadata_reject = Keyword.get(opts, :metadata_reject)
    verbose = Map.get(state, :verbose, false)
    socket_module = Keyword.get(opts, :socket_module)
    buffer_size = Keyword.get(opts, :buffer_size, @default_buffer_size)
    max_message_bytes = Keyword.get(opts, :max_message_bytes, @default_max_message_bytes)
    throttle_enabled = Keyword.get(opts, :throttle_enabled, true)
    throttle_window_sec = Keyword.get(opts, :throttle_window_sec, div(@default_throttle_window_ms, 1000))
    throttle_window_ms = throttle_window_sec * 1000
    throttle_max_repeats = Keyword.get(opts, :throttle_max_repeats, @default_throttle_max_repeats)
    verbose_file = Keyword.get(opts, :verbose_file, @default_verbose_file)
    exclude_message_containing = Keyword.get(opts, :exclude_message_containing, @default_exclude_containing)
    immediate_send_containing = Keyword.get(opts, :immediate_send_containing, @default_immediate_containing)

    %{
      state
      | name: name,
        format: format,
        level: level,
        metadata: metadata,
        metadata_filter: metadata_filter,
        metadata_reject: metadata_reject,
        verbose: verbose,
        socket_module: socket_module,
        buffer_size: buffer_size,
        max_message_bytes: max_message_bytes,
        throttle_enabled: throttle_enabled,
        throttle_window_ms: throttle_window_ms,
        throttle_max_repeats: throttle_max_repeats,
        verbose_file: verbose_file,
        exclude_message_containing: exclude_message_containing,
        immediate_send_containing: immediate_send_containing
    }
  end
end
