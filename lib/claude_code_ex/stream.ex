defmodule ClaudeCodeEx.Stream do
  @moduledoc """
  Provides a streaming interface for Claude queries.

  This module allows you to consume all events from a Claude query as an
  Elixir `Stream`, making it easy to integrate with other stream-based
  libraries or to use with `for` comprehensions.

  This is the recommended high-level API for most use cases.

  ## Stream Events

  The stream yields tuples of the form `{type, data}` where `type` is an atom
  representing the event. The most common events are:
  - `{:text, "some content"}` - A chunk of the AI's text response.
  - `{:tool_use, %{tool: "name", ...}}` - The agent is using a tool.
  - `{:tool_result, %{result: ...}}` - The result of a tool execution.
  - `{:thinking, "reasoning..."}` - The agent's thought process.
  - `{:message, %{...}}` - The final, complete message from the agent.
  - `{:error, reason}` - An error occurred during the query.

  ## Example

      {:ok, stream} = ClaudeCodeEx.stream_query("Tell me a short story.")

      stream
      |> Stream.filter(fn {type, _data} -> type == :text end)
      |> Stream.each(fn {:text, text_chunk} -> IO.write(text_chunk) end)
      |> Stream.run()
  """

  alias ClaudeCodeEx.Conversation

  defstruct query_id: nil, conversation_pid: nil, own_conversation?: false

  @type t :: %__MODULE__{
          query_id: String.t() | nil,
          conversation_pid: pid() | nil,
          own_conversation?: boolean()
        }

  @doc false
  # This function is not meant to be called directly.
  # Use `ClaudeCodeEx.stream_query/2` instead.
  def new(prompt, opts \\ []) do
    # Determine if we're using an existing conversation or starting a new one.
    case Keyword.get(opts, :conversation) do
      nil ->
        # No conversation provided, so we'll start a temporary one for this stream.
        {:ok, conv_pid} = Conversation.start_link(opts)
        create_stream_resource(prompt, conv_pid, opts, true)

      pid when is_pid(pid) ->
        # Use the provided conversation process.
        create_stream_resource(prompt, pid, opts, false)
    end
  end

  defp create_stream_resource(prompt, conv_pid, opts, own_conversation?) do
    case Conversation.query(conv_pid, prompt, opts) do
      {:ok, query_id} ->
        stream_state = %__MODULE__{
          query_id: query_id,
          conversation_pid: conv_pid,
          own_conversation?: own_conversation?
        }

        {:ok, Stream.resource(fn -> stream_state end, &next/1, &after/1)}

      {:error, reason} ->
        # If the query fails, shut down the temporary conversation if we started one.
        if own_conversation?, do: Conversation.stop(conv_pid)
        {:error, reason}
    end
  end

  # next/1 is the core of the stream. It receives messages for the query.
  defp next(%__MODULE__{query_id: query_id} = stream) do
    receive do
      {:agent_message, ^query_id, data} ->
        {[{:message, data}], stream}

      {:agent_event, ^query_id, :done, _data} ->
        {:halt, stream}

      {:agent_event, ^query_id, :error, reason} ->
        # Halt the stream on error, but emit the error first.
        {[{:error, reason}], %{stream | query_id: nil}} # Prevent further receives

      {:agent_event, ^query_id, type, data} ->
        {[{type, data}], stream}
    after
      30_000 ->
        {[{:error, :timeout}], %{stream | query_id: nil}}
    end
  end

  # after/1 is the cleanup function for the stream resource.
  defp after(%__MODULE__{} = stream) do
    # If this stream started its own temporary conversation, shut it down.
    if stream.own_conversation? and stream.conversation_pid do
      Conversation.stop(stream.conversation_pid)
    end

    :ok
  end
end