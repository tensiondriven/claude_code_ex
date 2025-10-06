defmodule ClaudeCodeEx.Conversation do
  @moduledoc """
  A GenServer that manages the state for a single, stateful conversation.

  This module is the engine behind stateful conversations. It's a `GenServer`
  that holds the conversation's settings, such as the system prompt and the
  list of available tools, between queries.

  While you can use this module directly, it's recommended to interact with
  conversations through the functions in the main `ClaudeCodeEx` module, such as:

  - `ClaudeCodeEx.start_conversation/1`
  - `ClaudeCodeEx.stream_query/2` (with the `:conversation` option)
  - `ClaudeCodeEx.stop_conversation/1`
  """

  use GenServer

  defmodule State do
    @moduledoc "Internal state for the Conversation GenServer."
    defstruct [:id, :owner, :tools, :model, :system_prompt, :working_dir]
  end

  # Client API

  @doc """
  Starts a conversation process and links it to the current process.

  This is the entry point for creating a new conversation. It's typically
  called via `ClaudeCodeEx.start_conversation/1`.

  ## Options

  - `tools`: A list of `ClaudeCodeEx.Tool` structs available for the conversation.
  - `model`: The model to use (e.g., "claude-3-opus-20240229").
  - `system_prompt`: The initial system prompt for the agent.
  - `working_dir`: The working directory for the agent.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Sends a query to a running conversation process.

  This is a lower-level function. For a more ergonomic experience, it's
  recommended to use `ClaudeCodeEx.stream_query/2` with the `:conversation`
  option, which handles message passing for you.
  """
  def query(conv_pid, prompt, opts \\ []) when is_pid(conv_pid) do
    GenServer.call(conv_pid, {:query, prompt, opts})
  end

  @doc """
  Stops the conversation process.

  Typically called via `ClaudeCodeEx.stop_conversation/1`.
  """
  def stop(conv_pid) when is_pid(conv_pid) do
    GenServer.stop(conv_pid)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    state = %State{
      id: generate_conversation_id(),
      owner: self(),
      tools: Keyword.get(opts, :tools, []),
      model: Keyword.get(opts, :model),
      system_prompt: Keyword.get(opts, :system_prompt),
      working_dir: Keyword.get(opts, :working_dir)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:query, prompt, opts}, from, %State{} = state) do
    # Combine the conversation's persistent options with any query-time options.
    combined_opts =
      [
        model: state.model,
        system_prompt: state.system_prompt,
        working_dir: state.working_dir
      ]
      |> Keyword.merge(opts)
      |> Keyword.put(:tools, state.tools)

    # The `from` variable is {caller_pid, tag}. We extract the caller's PID and
    # pass it to the PortServer as the owner of the query. This ensures async
    # messages are sent directly to the process that called this function.
    caller_pid = elem(from, 0)
    {:ok, query_id} = ClaudeCodeEx.PortServer.query(prompt, caller_pid, combined_opts)

    {:reply, {:ok, query_id}, state}
  end

  defp generate_conversation_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end