defmodule Eva.Extension.Memory.Transcript do
  @moduledoc """
  Flattens a session's messages into text the distiller can read.

  This is a lossy rendering on purpose. What survives is what a memory could plausibly
  be made of — what the user asked for, what the assistant concluded, which tools ran
  and whether they failed. What gets dropped is bulk that would crowd the distiller's
  context without changing its answer: thinking blocks, images, and the long tail of
  successful tool output.

  Failed tool results are kept in full where successful ones are truncated. An error is
  usually the most memorable thing in a session — "this is how that breaks" is exactly
  the kind of durable fact worth carrying forward, and it is also what the archaeology
  search gets asked about most.
  """

  alias Eva.Core.Agent.Messages

  # Successful tool output is context, not content: enough to know what happened.
  @ok_result_limit 400
  @error_result_limit 2_000
  @text_limit 4_000

  @doc """
  Renders messages to a single string.

  `:limit` caps the total, keeping the **end** of the conversation — conclusions live
  there, and a truncated beginning costs less than a truncated ending.
  """
  @spec render([struct()], keyword()) :: String.t()
  def render(messages, opts \\ []) do
    text =
      messages
      |> Enum.map(&render_message/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    case opts[:limit] do
      nil -> text
      limit -> tail(text, limit)
    end
  end

  defp render_message(%Messages.UserMessage{} = message) do
    case message |> Messages.UserMessage.text() |> String.trim() do
      "" -> nil
      text -> "USER: " <> clip(text, @text_limit)
    end
  end

  defp render_message(%Messages.AssistantMessage{} = message) do
    text = message |> Messages.AssistantMessage.text() |> String.trim()

    calls =
      message
      |> Messages.AssistantMessage.tool_calls()
      |> Enum.map_join("\n", fn call -> "  -> #{call.name}(#{summarize_args(call.arguments)})" end)

    [
      if(text != "", do: "ASSISTANT: " <> clip(text, @text_limit)),
      if(calls != "", do: "TOOLS:\n" <> calls)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> case do
      "" -> nil
      rendered -> rendered
    end
  end

  defp render_message(%Messages.ToolResultMessage{} = message) do
    text = message |> Messages.ToolResultMessage.text() |> String.trim()

    cond do
      text == "" ->
        nil

      message.is_error ->
        "TOOL FAILED (#{message.tool_name}): " <> clip(text, @error_result_limit)

      true ->
        "TOOL OK (#{message.tool_name}): " <> clip(text, @ok_result_limit)
    end
  end

  defp render_message(%Messages.BashExecutionMessage{} = message) do
    "BASH (exit #{message.exit_code}): #{message.command}\n" <>
      clip(to_string(message.output), @ok_result_limit)
  end

  # Compaction has already done the summarizing, so this is dense and worth keeping —
  # it is often the only trace of the early part of a long session.
  defp render_message(%Messages.CompactionSummaryMessage{summary: summary})
       when is_binary(summary) do
    "EARLIER (compacted): " <> clip(summary, @text_limit)
  end

  defp render_message(%Messages.BranchSummaryMessage{summary: summary})
       when is_binary(summary) do
    "EARLIER (branch): " <> clip(summary, @text_limit)
  end

  # Thinking, images, custom UI messages, branch summaries: not memory material.
  defp render_message(_), do: nil

  defp summarize_args(args) when is_map(args) do
    args
    |> Enum.map_join(", ", fn {key, value} -> "#{key}: #{clip(to_string_safe(value), 80)}" end)
    |> clip(200)
  end

  defp summarize_args(_), do: ""

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: inspect(value)

  defp clip(text, limit) when byte_size(text) <= limit, do: text
  defp clip(text, limit), do: String.slice(text, 0, limit) <> "…"

  defp tail(text, limit) when byte_size(text) <= limit, do: text

  defp tail(text, limit) do
    "…\n" <> String.slice(text, max(String.length(text) - limit, 0), limit)
  end
end
