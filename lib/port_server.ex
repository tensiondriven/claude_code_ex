defmodule ClaudeCodeEx.PortServer do
  @moduledoc """
  GenServer managing the Node.js process that interfaces with Claude Code SDK.

  This is the core component that:
  - Spawns and monitors a long-lived Node.js process running `agent.mjs`
  - Manages bidirectional JSON-over-stdio communication
  - Routes async responses back to caller processes via Elixir messages
  - Handles graceful restarts on Node.js process crashes
  - Provides test mode to avoid spawning Node.js in test environments

  ## Communication Protocol

  ### Request Format (Elixir → Node.js)

  All requests are JSON objects sent via the Port with a unique `query_id`:

      {
        "type": "query",
        "query_id": "AbCdEf123...",
        "prompt": "What files are in this directory?",
        "options": {
          "working_dir": "/path/to/dir",
          "tools": ["filesystem", "bash"],
          "model": "claude-opus-4"
        }
      }

  ### Response Format (Node.js → Elixir)

  The Node.js process sends multiple JSON messages per query:

      {"type": "message", "query_id": "...", "data": {...}}
      {"type": "tool_use", "query_id": "...", "tool": "filesystem", "args": {...}}
      {"type": "tool_result", "query_id": "...", "result": "..."}
      {"type": "thinking", "query_id": "...", "thinking": "..."}
      {"type": "text", "query_id": "...", "text": "..."}
      {"type": "done", "query_id": "..."}
      {"type": "error", "query_id": "...", "error": "..."}

  ## Process Lifecycle

  The PortServer is started by the supervisor on application boot and:

  1. Validates Node.js is available in PATH
  2. Locates the `agent.mjs` script in priv directory
  3. Spawns Node.js with environment variables (API key, etc.)
  4. Maintains a registry of pending queries awaiting responses
  5. Routes incoming JSON messages to waiting processes
  6. Cleans up state when queries complete

  ## Test Mode

  When `api_key: "test-key-not-used"` is configured, the server enters test mode:
  - No Node.js process is spawned
  - `ping/0` returns `:pong` immediately
  - `query/2` returns `{:error, :test_mode}`

  This enables testing without Node.js dependencies.

  ## Message Routing

  Callers receive async messages tagged with their `query_id`:

      # After calling query/2
      receive do
        {:agent_message, query_id, data} ->
          # Main response content

        {:agent_event, query_id, :tool_use, %{tool: tool, args: args}} ->
          # Claude is using a tool

        {:agent_event, query_id, :thinking, reasoning} ->
          # Claude's internal reasoning

        {:agent_event, query_id, :tool_result, %{result: result}} ->
          # Tool execution result
      end
  """

  use GenServer
  require Logger

  @type query_id :: String.t()
  @type request :: %{
          query_id: query_id(),
          type: :query,
          prompt: String.t(),
          options: map()
        }

  @doc """
  Starts the PortServer.

  ## Options
  - `:name` - GenServer name (default: `#{__MODULE__}`)
  - `:api_key` - Anthropic API key (required)
  - `:node_path` - Path to node executable (default: auto-detected)
  - `:agent_script` - Path to agent.mjs (default: priv/ts/agent.mjs)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Sends a query to the Claude Agent SDK.

  Returns `{:ok, query_id}` immediately. Responses are sent to the caller
  via messages: `{:agent_response, query_id, type, data}`.

  ## Examples

      {:ok, query_id} = ClaudeCodeEx.PortServer.query(
        "What files are in this directory?",
        working_dir: "/path/to/code",
        tools: ["filesystem"]
      )

  """
  @spec query(String.t(), keyword()) :: {:ok, query_id()} | {:error, term()}
  def query(prompt, opts \\ []) do
    GenServer.call(__MODULE__, {:query, prompt, opts})
  end

  @doc """
  Pings the Node process to check if it's alive.

  Returns `:pong` if responsive, `{:error, :timeout}` otherwise.
  """
  @spec ping(timeout()) :: :pong | {:error, :timeout}
  def ping(timeout \\ 5000) do
    GenServer.call(__MODULE__, :ping, timeout)
  end

  ## Callbacks

  @impl true
  def init(opts) do
    api_key = Keyword.fetch!(opts, :api_key)

    # In test mode with fake key, skip starting the port
    if api_key == "test-key-not-used" do
      {:ok, %{port: nil, pending: %{}, test_mode: true}}
    else
      node_path = Keyword.get(opts, :node_path) || System.find_executable("node")
      unless node_path, do: raise("node executable not found in PATH")

      agent_script =
        Keyword.get(opts, :agent_script) ||
          Path.join(:code.priv_dir(:claude_agent), "ts/agent.mjs")

      unless File.exists?(agent_script),
        do: raise("agent.mjs not found at #{agent_script}")

      base_url = Application.get_env(:claude_agent, :base_url)

      env =
        [
          {"ANTHROPIC_API_KEY", api_key},
          {"NODE_ENV", to_string(Mix.env())}
        ]
        |> maybe_add_base_url(base_url)

      port =
        Port.open(
          {:spawn_executable, node_path},
          [
            {:args, [agent_script]},
            {:env, env},
            :binary,
            :exit_status,
            {:line, 10000},
            :stderr_to_stdout
          ]
        )

      state = %{
        port: port,
        pending: %{},
        node_path: node_path,
        agent_script: agent_script,
        test_mode: false
      }

      {:ok, state}
    end
  end

  @impl true
  def handle_call({:query, prompt, opts}, from, state) do
    if state[:test_mode] do
      {:reply, {:error, :test_mode}, state}
    else
      query_id = generate_query_id()

      request = %{
        type: "query",
        query_id: query_id,
        prompt: prompt,
        options: opts_to_js_options(opts)
      }

      json = Jason.encode!(request)
      Port.command(state.port, json <> "\n")

      # Store caller info
      pending = Map.put(state.pending, query_id, %{from: from, messages: []})

      {:noreply, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_call(:ping, from, state) do
    if state[:test_mode] do
      GenServer.reply(from, :pong)
      {:noreply, state}
    else
      ping_id = generate_query_id()

      request = %{type: "ping", query_id: ping_id}
      json = Jason.encode!(request)
      Port.command(state.port, json <> "\n")

      pending = Map.put(state.pending, ping_id, %{from: from, type: :ping})

      {:noreply, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, response} ->
        handle_response(response, state)

      {:error, error} ->
        Logger.error("Failed to decode JSON from Node: #{inspect(error)}\nLine: #{line}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("Node process exited with status #{status}")

    # Notify all pending queries
    Enum.each(state.pending, fn {_query_id, %{from: from}} ->
      GenServer.reply(from, {:error, {:node_exit, status}})
    end)

    {:stop, {:node_exit, status}, state}
  end

  ## Private Functions

  defp handle_response(%{"type" => "pong"} = response, state) do
    query_id = response["query_id"]

    case Map.get(state.pending, query_id) do
      %{from: from, type: :ping} ->
        GenServer.reply(from, :pong)
        pending = Map.delete(state.pending, query_id)
        {:noreply, %{state | pending: pending}}

      _ ->
        {:noreply, state}
    end
  end

  defp handle_response(%{"type" => "message", "query_id" => query_id} = response, state) do
    case Map.get(state.pending, query_id) do
      %{from: from} = query_state ->
        # Accumulate messages
        messages = [response["data"] | query_state.messages]
        pending = Map.put(state.pending, query_id, %{query_state | messages: messages})

        # Send intermediate update to caller
        send(elem(from, 0), {:agent_message, query_id, response["data"]})

        {:noreply, %{state | pending: pending}}

      nil ->
        Logger.warning("Received message for unknown query_id: #{query_id}")
        {:noreply, state}
    end
  end

  defp handle_response(%{"type" => "tool_use", "query_id" => query_id} = response, state) do
    case Map.get(state.pending, query_id) do
      %{from: from} ->
        send(
          elem(from, 0),
          {:agent_event, query_id, :tool_use,
           %{
             tool: response["tool"],
             args: response["args"],
             tool_use_id: response["tool_use_id"]
           }}
        )

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  defp handle_response(%{"type" => "text", "query_id" => query_id} = response, state) do
    case Map.get(state.pending, query_id) do
      %{from: from} ->
        send(elem(from, 0), {:agent_event, query_id, :text, response["text"]})
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  defp handle_response(%{"type" => "thinking", "query_id" => query_id} = response, state) do
    case Map.get(state.pending, query_id) do
      %{from: from} ->
        send(elem(from, 0), {:agent_event, query_id, :thinking, response["thinking"]})
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  defp handle_response(%{"type" => "tool_result", "query_id" => query_id} = response, state) do
    case Map.get(state.pending, query_id) do
      %{from: from} ->
        send(
          elem(from, 0),
          {:agent_event, query_id, :tool_result,
           %{tool_use_id: response["tool_use_id"], result: response["result"]}}
        )

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  defp handle_response(%{"type" => "partial_message", "query_id" => query_id} = response, state) do
    case Map.get(state.pending, query_id) do
      %{from: from} ->
        send(elem(from, 0), {:agent_event, query_id, :partial_message, response["delta"]})
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  defp handle_response(%{"type" => "system", "query_id" => query_id} = response, state) do
    case Map.get(state.pending, query_id) do
      %{from: from} ->
        send(elem(from, 0), {:agent_event, query_id, :system, response["system_message"]})
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  defp handle_response(%{"type" => "done", "query_id" => query_id}, state) do
    case Map.pop(state.pending, query_id) do
      {%{from: from, messages: messages}, pending} ->
        # Reply with all accumulated messages
        GenServer.reply(from, {:ok, Enum.reverse(messages)})
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        Logger.warning("Received done for unknown query_id: #{query_id}")
        {:noreply, state}
    end
  end

  defp handle_response(%{"type" => "error", "query_id" => query_id} = response, state) do
    case Map.pop(state.pending, query_id) do
      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, response["error"]})
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        Logger.warning("Received error for unknown query_id: #{query_id}")
        {:noreply, state}
    end
  end

  defp handle_response(response, state) do
    Logger.warning("Unknown response type: #{inspect(response)}")
    {:noreply, state}
  end

  defp generate_query_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp opts_to_js_options(opts) do
    %{
      working_dir: Keyword.get(opts, :working_dir),
      tools: Keyword.get(opts, :tools),
      system_prompt: Keyword.get(opts, :system_prompt),
      model: Keyword.get(opts, :model)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp maybe_add_base_url(env, nil), do: env

  defp maybe_add_base_url(env, base_url) do
    [{"ANTHROPIC_BASE_URL", base_url} | env]
  end
end
