defmodule ClaudeCodeEx do
  @moduledoc """
  Elixir wrapper for the Claude Agent SDK 2.0.

  `ClaudeCodeEx` provides a clean Elixir API for interacting with Anthropic's
  Claude Agent SDK 2.0, bringing the full agentic capabilities of Claude Code
  to Phoenix and LiveView applications.

  ## What is Claude Agent SDK?

  The Claude Agent SDK enables you to build autonomous AI agents with Claude Code's
  capabilities. Unlike basic LLM APIs, these agents can:

  - **Execute multi-step workflows** - Break down complex tasks and complete them autonomously
  - **Use tools** - Interact with filesystems, search the web, analyze code, run commands
  - **Manage context** - Automatically prune and optimize conversation context
  - **Handle permissions** - Fine-grained control over file access and command execution

  Learn more: [Claude Agent SDK Documentation](https://docs.claude.com/en/api/agent-sdk/overview)

  ## Installation

  Add `claude_code_ex` to your `mix.exs`:

  ```elixir
  def deps do
    [
      {:claude_code_ex, "~> 0.1.0"}
    ]
  end
  ```

  ## Configuration

  ### Using Anthropic API

  ```elixir
  # config/config.exs
  config :claude_code_ex,
    api_key: System.get_env("ANTHROPIC_API_KEY")
  ```

  ### Using OpenRouter with GLM Models

  ```elixir
  # config/config.exs
  config :claude_code_ex,
    api_key: System.get_env("OPENROUTER_API_KEY"),
    base_url: "https://openrouter.ai/api/v1"
  ```

  Then specify the model in your queries:

  ```elixir
  {:ok, response} = ClaudeCodeEx.query(
    "What is 2 + 2?",
    model: "glm-4.5-turbo"
  )
  ```

  The package will automatically start the agent process when your application starts.

  ## Usage

  ### Simple Query

      {:ok, response} = ClaudeCodeEx.query("What is 2 + 2?")
      # => {:ok, "4"}

  ### Using Tools

      {:ok, response} = ClaudeCodeEx.query(
        "Search the web for Elixir best practices and summarize them",
        tools: ["web_search"]
      )

  ### Filesystem Operations

      {:ok, response} = ClaudeCodeEx.query(
        "List all .ex files in this directory and count the lines of code",
        working_dir: "/path/to/project",
        tools: ["filesystem", "code_search"]
      )

  ### Multi-Step Workflows

      {:ok, response} = ClaudeCodeEx.query(
        \"\"\"
        1. Search the web for the latest Phoenix LiveView best practices
        2. Analyze my codebase
        3. Suggest specific improvements
        \"\"\",
        working_dir: "/path/to/phoenix/app",
        tools: ["web_search", "filesystem", "code_search"]
      )

  ### Async Queries with Callbacks

  For real-time UI updates in LiveView:

      callback = fn type, data ->
        # Broadcast to LiveView
        Phoenix.PubSub.broadcast(
          MyApp.PubSub,
          "room:\#{room_id}",
          {:agent_update, type, data}
        )
      end

      {:ok, query_id} = ClaudeCodeEx.query_async(
        "Refactor this module",
        [working_dir: "/path", tools: ["filesystem"]],
        callback
      )

  ## Available Tools

  The Claude Agent SDK 2.0 provides these built-in tools:

  - `"filesystem"` - Read/write files, list directories
  - `"code_search"` - Search and analyze codebases
  - `"web_search"` - Search the web for information
  - `"command_execution"` - Run shell commands (requires permissions)

  ## Architecture

  ```
  Phoenix LiveView
      ↓
  ClaudeCodeEx (Elixir)
      ↓ (Port/stdio)
  Node.js (agent.mjs)
      ↓
  @anthropic-ai/claude-code
      ↓
  Claude API
  ```

  The TypeScript SDK runs in a supervised Node.js process, communicating
  via stdio. This keeps all the agent capabilities while providing an
  Elixir-native API.

  ## Integration with ash_chat

  See the [ash_chat integration guide](guides/ash_chat_integration.md) for
  details on wiring ClaudeCodeEx into your Ash Framework chat application.

  ## Why Not ash_ai?

  `ash_ai` provides basic LLM wrappers. ClaudeCodeEx wraps the **full Claude Code
  agent harness** - multi-turn conversations, autonomous tool use, context management,
  and all the agentic capabilities that power Claude Code itself.

  If you need simple LLM calls, use `ash_ai`. If you need autonomous agents that
  can complete complex tasks, use ClaudeCodeEx.
  """

  alias ClaudeCodeEx.PortServer

  @type query_options :: [
          working_dir: String.t(),
          tools: [String.t()],
          system_prompt: String.t()
        ]

  @type callback :: (atom(), any() -> any())

  @doc """
  Sends a synchronous query to the Claude Agent SDK.

  Returns `{:ok, response}` when the agent completes the task.
  The response is a string containing the agent's final answer.

  ## Options

  - `:working_dir` - Working directory for filesystem operations (default: current directory)
  - `:tools` - List of tools to enable: `["filesystem", "web_search", "code_search"]`
  - `:system_prompt` - Optional system prompt to guide the agent's behavior
  - `:model` - Model to use (e.g., `"anthropic/claude-3-5-sonnet"`, `"glm-4.5-turbo"` for OpenRouter/GLM)

  ## Examples

      {:ok, response} = ClaudeCodeEx.query("What is 2 + 2?")
      # => {:ok, "2 + 2 equals 4."}

      {:ok, response} = ClaudeCodeEx.query(
        "List all Elixir files",
        working_dir: "/path/to/project",
        tools: ["filesystem"]
      )

  ## Tool Usage

  When tools are specified, the agent can use them autonomously:

      {:ok, response} = ClaudeCodeEx.query(
        "Search for Elixir OTP patterns and apply them to my GenServer",
        working_dir: "/path/to/code",
        tools: ["web_search", "filesystem"]
      )

  The agent will:
  1. Search the web for OTP patterns
  2. Read your GenServer code
  3. Suggest specific improvements
  4. Return a comprehensive response

  ## Error Handling

      case ClaudeCodeEx.query("Help me refactor this") do
        {:ok, response} ->
          IO.puts(response)

        {:error, reason} ->
          Logger.error("Query failed: \#{inspect(reason)}")
      end

  """
  @spec query(String.t(), query_options()) :: {:ok, String.t()} | {:error, term()}
  def query(prompt, opts \\ []) do
    case PortServer.query(prompt, opts) do
      {:ok, messages} ->
        # Extract final text response from messages
        response = extract_final_response(messages)
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends an asynchronous query with a callback for intermediate updates.

  Returns `{:ok, query_id}` immediately. The callback is invoked for each
  update from the agent.

  ## Callback Arguments

  The callback receives `(event_type, data)` where event_type can be:

  - `:message` - Full agent message (includes all content blocks)
  - `:text` - Text response chunk from the agent
  - `:thinking` - Agent's internal reasoning/thinking trace
  - `:tool_use` - Agent is using a tool: `%{tool: name, args: map, tool_use_id: id}`
  - `:tool_result` - Tool execution result: `%{tool_use_id: id, result: data}`
  - `:partial_message` - Streaming message delta (real-time updates)
  - `:system` - System messages (permissions, errors, etc.)
  - `:done` - Query completed
  - `:error` - Error occurred

  ## Examples

      callback = fn
        :text, text ->
          IO.puts("Agent: \#{text}")

        :thinking, reasoning ->
          IO.puts("Agent thinking: \#{reasoning}")

        :tool_use, %{tool: tool, args: args} ->
          IO.puts("Using \#{tool} with \#{inspect(args)}")

        :tool_result, %{tool_use_id: id, result: result} ->
          IO.puts("Tool result: \#{inspect(result)}")

        :done, _ ->
          IO.puts("Query completed")

        :error, reason ->
          IO.puts("Error: \#{reason}")

        _other, _data ->
          :ok
      end

      {:ok, query_id} = ClaudeCodeEx.query_async(
        "Analyze this codebase",
        [working_dir: "/path", tools: ["code_search"]],
        callback
      )

  ## LiveView Integration

  Hook into all agent events for real-time UI updates:

      def handle_event("ask_agent", %{"prompt" => prompt}, socket) do
        callback = fn type, data ->
          send(self(), {:agent_event, type, data})
        end

        {:ok, query_id} = ClaudeCodeEx.query_async(
          prompt,
          [working_dir: socket.assigns.project_path, tools: ["filesystem"]],
          callback
        )

        {:noreply, assign(socket, query_id: query_id, agent_status: :thinking)}
      end

      def handle_info({:agent_event, :text, text}, socket) do
        # Stream text responses in real-time
        {:noreply, update(socket, :response_text, &(&1 <> text))}
      end

      def handle_info({:agent_event, :thinking, reasoning}, socket) do
        # Show agent's internal reasoning
        {:noreply, assign(socket, thinking: reasoning)}
      end

      def handle_info({:agent_event, :tool_use, %{tool: tool}}, socket) do
        # Show which tool the agent is using
        {:noreply, assign(socket, current_tool: tool)}
      end

      def handle_info({:agent_event, :tool_result, result}, socket) do
        # Display tool results
        {:noreply, update(socket, :tool_results, &[result | &1])}
      end

      def handle_info({:agent_event, :done, _}, socket) do
        {:noreply, assign(socket, agent_status: :complete)}
      end

  """
  @spec query_async(String.t(), query_options(), callback()) ::
          {:ok, String.t()} | {:error, term()}
  def query_async(prompt, opts \\ [], callback) when is_function(callback, 2) do
    parent = self()

    # Start async task that receives events while PortServer.query blocks
    Task.start(fn ->
      # Spawn a separate process to handle the blocking query
      query_task = Task.async(fn -> PortServer.query(prompt, opts) end)

      # Receive events while the query is running
      receive_and_forward_events(parent, callback, query_task)

      # Wait for final result
      case Task.await(query_task, :infinity) do
        {:ok, _messages} ->
          # All events already forwarded, send done
          callback.(:done, nil)
          send(parent, {:agent_callback, :done, nil})

        {:error, reason} ->
          callback.(:error, reason)
          send(parent, {:agent_callback, :error, reason})
      end
    end)

    # Generate and return query_id for tracking
    query_id = generate_query_id()
    {:ok, query_id}
  end

  # Private helper to receive events from PortServer and forward to callback
  defp receive_and_forward_events(parent, callback, query_task) do
    receive do
      {:agent_event, query_id, event_type, data} ->
        send(parent, {:agent_callback, query_id, event_type, data})
        callback.(event_type, data)
        receive_and_forward_events(parent, callback, query_task)

      {:agent_message, query_id, msg} ->
        send(parent, {:agent_callback, query_id, :message, msg})
        callback.(:message, msg)
        receive_and_forward_events(parent, callback, query_task)

    after
      100 ->
        # Check if query task is still running
        if Process.alive?(query_task.pid) do
          receive_and_forward_events(parent, callback, query_task)
        end
    end
  end

  @doc """
  Pings the Claude Agent SDK process to check if it's responsive.

  Returns `:pong` if healthy, `{:error, :timeout}` if not responding.

  ## Examples

      case ClaudeCodeEx.ping() do
        :pong ->
          IO.puts("Agent is healthy")

        {:error, :timeout} ->
          Logger.error("Agent not responding")
      end

  """
  @spec ping(timeout()) :: :pong | {:error, :timeout}
  def ping(timeout \\ 5000) do
    PortServer.ping(timeout)
  end

  ## Private Functions

  defp extract_final_response(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{"type" => "assistant", "content" => content} when is_list(content) ->
        content
        |> Enum.filter(&(&1["type"] == "text"))
        |> Enum.map(& &1["text"])
        |> Enum.join("\n")

      %{"type" => "assistant", "content" => text} when is_binary(text) ->
        text

      _ ->
        nil
    end)
  end

  defp extract_final_response(_), do: ""

  defp generate_query_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
