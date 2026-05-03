# Copyright 2015 Marcelo Gornstein <marcelog@gmail.com>
# Adapted for Intuitivo firmware sockets (CloudWatch, throttle, verbose, buffers).
# Licensed under the Apache License, Version 2.0.
defmodule LoggerIntuitivoBackend do
  @moduledoc """
  Logger backend that sends logs through the firmware Socket (e.g. to CloudWatch).
  Supports verbose mode, buffering with size limit, throttling of repeated messages,
  and configurable filters (exclude SQUASHFS, immediate health check).

  ## Verbose off (buffered mode)

  - **`verbose: true`**: each matching log is sent immediately (firmware lines via
    `send_log/1`, others via `send_system/1` when the socket supports it).
  - **`verbose: false`**: lines are batched. A batch is sent when **either**:
    1. The joined payload would reach or exceed **`max_message_bytes`**, or
    2. The buffer holds **`max_buffer_lines`** lines (hard cap so very short lines
       cannot grow without bound).

  Reaching **`buffer_size`** lines alone **does not** send anything if the joined
  size is still under **`max_message_bytes`**: many short lines keep accumulating
  until the byte limit or **`max_buffer_lines`** is reached. Use `Logger.flush/0`
  to force-send whatever is pending (e.g. before shutdown).

  **`buffer_size`** is kept for configuration compatibility and for deriving the
  default **`max_buffer_lines`** when you omit it; it is **not** a flush trigger.

  Before send, **similar** lines in the same batch are collapsed to a single line
  (same *similarity fingerprint*: timestamp-stripped body, numbers normalized to `#`).
  """
  @behaviour :gen_event

  @default_format "$date $time [$level] $metadata $message\n"
  @default_buffer_size 8
  @default_max_message_bytes 8 * 1024
  # Hard line cap when many short lines never reach max_message_bytes.
  @default_max_buffer_lines 128
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
    %{socket_module: socket_module} = state

    if is_nil(socket_module) or new_buf == [] do
      %{state | buffer_logs_firmware: new_buf}
    else
      if should_flush_buffer?(new_buf, state) do
        combined = combine_buffer_for_send(new_buf, state.max_message_bytes)
        socket_module.send_log({combined, random_id()})
        %{state | buffer_logs_firmware: []}
      else
        %{state | buffer_logs_firmware: new_buf}
      end
    end
  end

  defp maybe_flush_system_buffer(new_buf, state) do
    %{socket_module: socket_module} = state

    if is_nil(socket_module) or new_buf == [] do
      %{state | buffer_logs_system: new_buf}
    else
      if should_flush_buffer?(new_buf, state) do
        combined = combine_buffer_for_send(new_buf, state.max_message_bytes)
        send_system(socket_module, combined)
        %{state | buffer_logs_system: []}
      else
        %{state | buffer_logs_system: new_buf}
      end
    end
  end

  # new_buf: newest line first (prepended in do_send).
  # Only byte size or the line cap flush — never line count alone (e.g. buffer_size),
  # so many short lines keep accumulating until max_message_bytes or max_buffer_lines.
  defp should_flush_buffer?(new_buf, state) do
    %{max_buffer_lines: cap_lines, max_message_bytes: max_bytes} = state
    n = length(new_buf)
    raw_bytes = buffer_joined_byte_size(new_buf)

    raw_bytes >= max_bytes or n >= cap_lines
  end

  defp buffer_joined_byte_size(lines) do
    lines
    |> Enum.reverse()
    |> Enum.join("\n")
    |> byte_size()
  end

  defp combine_buffer_for_send(lines, max_bytes) do
    lines
    |> dedupe_similar_lines()
    |> combine_and_truncate(max_bytes)
  end

  @doc false
  # Collapse lines in the same batch that look the same (timestamp / numbers differ).
  # Keeps the first occurrence in chronological order (oldest kept). Returns newest-first
  # (same convention as the internal buffers) for `combine_and_truncate/2`.
  def dedupe_similar_lines(lines_newest_first) when is_list(lines_newest_first) do
    kept_oldest_first =
      lines_newest_first
      |> Enum.reverse()
      |> Enum.reduce({[], MapSet.new()}, fn line, {acc, seen} ->
        fp = line_similarity_fingerprint(line)

        if MapSet.member?(seen, fp) do
          {acc, seen}
        else
          {acc ++ [line], MapSet.put(seen, fp)}
        end
      end)
      |> elem(0)

    Enum.reverse(kept_oldest_first)
  end

  defp line_similarity_fingerprint(line) when is_binary(line) do
    line
    |> String.replace(~r/\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+/, " ")
    |> String.replace(~r/\bpid[= ]#?\d+/i, "pid=#")
    |> String.replace(~r/\b(?:0x[0-9a-fA-F]{4,})\b/u, "#")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
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
      <<head::binary-size(keep), _::binary>> = combined
      head <> suffix
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
        combined = combine_buffer_for_send(buf_fw, max_bytes)
        socket_module.send_log({combined, random_id()})
      end

      if buf_sys != [] do
        combined = combine_buffer_for_send(buf_sys, max_bytes)
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
      max_buffer_lines: @default_max_buffer_lines,
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

    # Must read from merged opts so Logger.configure_backend(..., verbose: false) applies;
    # otherwise a prior :verbose true sticks in state and system logs bypass the buffer.
    verbose = Keyword.get(opts, :verbose, Map.get(state, :verbose, false))

    socket_module =
      Keyword.get(opts, :socket_module) || Map.get(state, :socket_module)
    buffer_size =
      Keyword.get(opts, :buffer_size) ||
        Map.get(state, :buffer_size, @default_buffer_size)

    max_message_bytes =
      Keyword.get(opts, :max_message_bytes) ||
        Map.get(state, :max_message_bytes, @default_max_message_bytes)

    max_buffer_lines =
      Keyword.get(opts, :max_buffer_lines) ||
        Map.get(state, :max_buffer_lines) ||
        max(max(@default_max_buffer_lines, buffer_size * 4), buffer_size)
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
        max_buffer_lines: max_buffer_lines,
        throttle_enabled: throttle_enabled,
        throttle_window_ms: throttle_window_ms,
        throttle_max_repeats: throttle_max_repeats,
        verbose_file: verbose_file,
        exclude_message_containing: exclude_message_containing,
        immediate_send_containing: immediate_send_containing
    }
  end
end
