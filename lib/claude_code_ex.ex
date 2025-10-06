defmodule ClaudeCodeEx do
  @moduledoc """
  Elixir wrapper for the Claude Code SDK.

  Provides a supervised Port-based interface to the Claude Code SDK (npm package),
  enabling Elixir applications to interact with Claude AI through a managed Node.js process.

  ## Quick Start

  Configure your API key:

      # config/config.exs
      config :claude_code_ex,
        api_key: System.get_env("ANTHROPIC_API_KEY")

  Query Claude:

      {:ok, query_id} = ClaudeCodeEx.query("What files are in this directory?")

      receive do
        {:agent_message, ^query_id, data} -> IO.inspect(data)
        {:agent_event, ^query_id, :tool_use, tool_data} -> IO.inspect(tool_data)
      end

  ## Architecture

  ```
  Elixir Application
      ↓
  ClaudeCodeEx (Public API)
      ↓
  PortServer (GenServer managing Node.js)
      ↕ (stdio/JSON)
  Node.js process (agent.mjs)
      ↓
  @anthropic-ai/claude-code
      ↓
  Anthropic API
  ```

  ## Message Types

  ### Agent Messages

  Main content responses from Claude:

      {:agent_message, query_id, data}

  ### Agent Events

  Real-time events during query processing:

      {:agent_event, query_id, :tool_use, %{tool: "bash", args: %{...}}}
      {:agent_event, query_id, :tool_result, %{result: "..."}}
      {:agent_event, query_id, :thinking, "Claude's reasoning"}
      {:agent_event, query_id, :text, "partial response"}

  ## Configuration

  All configuration options:

      config :claude_code_ex,
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        node_path: "/usr/local/bin/node",           # Optional: custom node path
        agent_script: "/custom/agent.mjs",           # Optional: custom agent script
        base_url: "https://api.custom.com"           # Optional: API proxy/endpoint

  ## Testing

  Use test mode to avoid starting Node.js in tests:

      # config/test.exs
      config :claude_code_ex,
        api_key: "test-key-not-used"

  ## Query Options

  Customize queries with options:

      ClaudeCodeEx.query(
        "Analyze this codebase",
        working_dir: "/path/to/project",
        tools: ["filesystem", "bash"],
        system_prompt: "You are a code reviewer",
        model: "claude-opus-4"
      )
  """

  @doc """
  Sends a query to Claude.

  See `ClaudeCodeEx.PortServer.query/2` for details.
  """
  defdelegate query(prompt, opts \\ []), to: ClaudeCodeEx.PortServer

  @doc """
  Pings the Node.js process to check if it's alive.

  See `ClaudeCodeEx.PortServer.ping/1` for details.
  """
  defdelegate ping(timeout \\ 5000), to: ClaudeCodeEx.PortServer
end
