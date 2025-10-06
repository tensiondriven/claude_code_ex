defmodule ClaudeCodeEx do
  @moduledoc """
  An Elixir wrapper for the **@anthropic-ai/claude-agent-sdk**.

  This library provides a robust, concurrent, and fault-tolerant interface to
  build powerful AI agents with Elixir. It manages a Node.js process running
  the official Claude Agent SDK and exposes its features through an idiomatic
  Elixir API.

  ## Core Features

  - **Streaming API**: The recommended way to interact with the agent. Use
    `stream_query/2` to get an Elixir `Stream` of agent events.
  - **Stateful Conversations**: Use `start_conversation/1` to create a
    `GenServer`-backed session that remembers context between queries.
  - **Elixir-Defined Tools**: Define custom tools directly in your Elixir
    code using the `ClaudeCodeEx.Tool` struct and let the agent execute them.

  ## Quick Start

  First, configure your API key in `config/config.exs`:

      config :claude_code_ex,
        api_key: System.get_env("ANTHROPIC_API_KEY")

  ### Using the Streaming API

  This is the simplest and most powerful way to get started.

      {:ok, stream} = ClaudeCodeEx.stream_query("Tell me a short story about OTP.")

      stream
      |> Stream.filter(fn {type, _data} -> type == :text end)
      |> Enum.each(fn {:text, chunk} -> IO.write(chunk) end)

  ### Managing Stateful Conversations

      # Start a conversation with a system prompt
      {:ok, conv_pid} = ClaudeCodeEx.start_conversation(system_prompt: "You are a pirate.")

      # The stream will now use the context of the conversation
      {:ok, stream} = ClaudeCodeEx.stream_query("What is Elixir?", conversation: conv_pid)

      # ... process the stream ...

  ## Elixir-Defined Tools

  Define a tool using the `ClaudeCodeEx.Tool` struct and pass it to a query
  or conversation.

      defmodule MyTools do
        def add_tool do
          %ClaudeCodeEx.Tool{
            name: "add",
            description: "Adds two numbers.",
            input_schema: %{...},
            implementation: fn %{"a" => a, "b" => b} -> a + b end
          }
        end
      end

      tools = [MyTools.add_tool()]
      {:ok, stream} = ClaudeCodeEx.stream_query("What is 2 + 2?", tools: tools)

      # You can observe the :tool_use and :tool_result events in the stream.

  ## Low-Level API

  For cases where you need more control, you can use the lower-level query
  functions and manage the message passing manually.

      {:ok, query_id} = ClaudeCodeEx.query("What is your name?")

      receive do
        {:agent_event, ^query_id, type, data} ->
          IO.inspect({type, data})
      after
        5000 -> :timeout
      end
  """

  alias ClaudeCodeEx.Conversation
  alias ClaudeCodeEx.Stream
  alias ClaudeCodeEx.PortServer

  @doc """
  Sends a stateless query to Claude and returns the `query_id`.

  This is a lower-level function. For most use cases, `stream_query/2` is
  recommended.

  Responses will be sent to the calling process as messages.
  See the module documentation for message formats.
  """
  def query(prompt, opts \\ []) do
    PortServer.query(prompt, nil, opts)
  end

  @doc """
  Starts a new, stateful conversation process.

  Returns `{:ok, pid}` where `pid` is the process ID of the `GenServer`
  managing the conversation. This PID can be passed to `stream_query/2` or
  `query_conversation/3`.

  See `ClaudeCodeEx.Conversation.start_link/1` for all available options.
  """
  defdelegate start_conversation(opts \\ []), to: Conversation, as: :start_link

  @doc """
  Sends a query within an existing stateful conversation.

  This is a lower-level function. It's recommended to use `stream_query/2`
  with the `:conversation` option instead.

  - `conversation`: The PID or registered name of the conversation process.
  - `prompt`: The user's prompt.
  - `opts`: Additional query-time options.
  """
  defdelegate query_conversation(conversation, prompt, opts \\ []), to: Conversation, as: :query

  @doc """
  Stops a running conversation process.
  """
  defdelegate stop_conversation(conversation), to: Conversation, as: :stop

  @doc """
  Performs a query and returns the agent events as an Elixir `Stream`.

  This is the recommended way to interact with the agent. The returned stream
  will emit events as `{:type, data}` tuples. The stream will halt on `:done`
  or `:error` events.

  ## Options

  - `:conversation`: A PID of a running conversation to use for context.
  - All other options supported by `ClaudeCodeEx.Conversation.start/1`, such
    as `:tools`, `:model`, etc. If a `:conversation` is provided, these options
    will be merged with the conversation's existing settings.
  """
  defdelegate stream_query(prompt, opts \\ []), to: Stream, as: :new

  @doc """
  Pings the underlying Node.js process to check if it's alive.

  Returns `:pong` on success or `{:error, :timeout}`.
  """
  defdelegate ping(timeout \\ 5000), to: PortServer
end