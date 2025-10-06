# ClaudeCodeEx

Elixir wrapper for the [Claude Code SDK](https://www.npmjs.com/package/@anthropic-ai/claude-code) (npm package).

Enables Elixir applications to interact with Claude AI through a supervised Port-based communication channel with Node.js.

## Installation

Add `claude_code_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:claude_code_ex, "~> 0.1.0"}
  ]
end
```

## Prerequisites

- Node.js installed and available in PATH
- Anthropic API key

## Configuration

Configure your API key:

```elixir
# config/config.exs
config :claude_code_ex,
  api_key: System.get_env("ANTHROPIC_API_KEY")
```

## Architecture

```
Elixir Application
    ↓
ClaudeCodeEx (Public API)
    ↓
PortServer (GenServer managing Node.js process)
    ↕ (stdio/JSON communication)
Node.js process (agent.mjs)
    ↓
@anthropic-ai/claude-code (npm package)
    ↓
Anthropic API
```

The library:
- Starts a supervised Node.js process on application boot
- Communicates via JSON over stdio
- Routes responses back to calling processes via Elixir messages
- Automatically restarts the Node process on crashes

## Usage

### Basic Query

```elixir
{:ok, query_id} = ClaudeCodeEx.query("What files are in this directory?")

# Handle responses via pattern matching
receive do
  {:agent_message, ^query_id, data} ->
    IO.puts("Claude says: #{inspect(data)}")

  {:agent_event, ^query_id, :tool_use, %{tool: tool}} ->
    IO.puts("Claude is using tool: #{tool}")

  {:agent_event, ^query_id, :thinking, thinking} ->
    IO.puts("Claude is thinking: #{thinking}")
end
```

### With Options

```elixir
ClaudeCodeEx.query(
  "Analyze this codebase",
  working_dir: "/path/to/project",
  tools: ["filesystem", "bash"],
  model: "claude-opus-4"
)
```

### Health Check

```elixir
case ClaudeCodeEx.ping() do
  :pong -> IO.puts("Node.js process is healthy")
  {:error, :timeout} -> IO.puts("Node.js process not responding")
end
```

## Message Types

The PortServer sends different message types to the calling process:

### `:agent_message`
Main response content from Claude.

```elixir
{:agent_message, query_id, data}
```

### `:agent_event`
Events during processing:

```elixir
{:agent_event, query_id, :tool_use, %{tool: "filesystem", args: %{...}}}
{:agent_event, query_id, :tool_result, %{result: "..."}}
{:agent_event, query_id, :thinking, "thinking content"}
{:agent_event, query_id, :text, "partial text"}
{:agent_event, query_id, :partial_message, delta}
{:agent_event, query_id, :system, "system message"}
```

## AshAi Integration

Expose your Ash Framework actions as tools that Claude can call directly:

```elixir
# Define tools in your Ash domain
defmodule MyApp.Blog do
  use Ash.Domain, extensions: [AshAi]

  tools do
    tool :list_posts, MyApp.Blog.Post, :read
    tool :create_post, MyApp.Blog.Post, :create
    tool :publish_post, MyApp.Blog.Post, :publish
  end
end

# Use them in queries
{:ok, response} = ClaudeCodeEx.query(
  "Create a blog post about Elixir patterns and publish it",
  ash_tools: [otp_app: :my_app, actor: current_user]
)

# Or with specific domains
{:ok, response} = ClaudeCodeEx.query(
  "List all users and their recent posts",
  ash_tools: [
    domains: [MyApp.Blog, MyApp.Accounts],
    actor: current_user,
    tenant: tenant_id
  ]
)
```

The integration:
- Automatically discovers AshAi tools from your application
- Converts them to Claude Code SDK tool format
- Routes tool calls back to Elixir to execute Ash actions
- Supports actor context and multi-tenancy
- Works with all CRUD action types

## Advanced Configuration

```elixir
# Anthropic (default)
config :claude_code_ex,
  api_key: System.get_env("ANTHROPIC_API_KEY")

# OpenRouter (for GLM-4.5, GPT-4, etc.)
config :claude_code_ex,
  api_key: System.get_env("OPENROUTER_API_KEY"),
  base_url: "https://openrouter.ai/api/v1"

# Local LLM (Ollama, vLLM, LMStudio)
config :claude_code_ex,
  api_key: "not-used",
  base_url: "http://localhost:11434/v1"  # Ollama
  # base_url: "http://localhost:8000/v1"  # vLLM
  # base_url: "http://localhost:1234/v1"  # LMStudio

# Custom paths
config :claude_code_ex,
  node_path: "/custom/path/to/node",
  agent_script: "/custom/path/to/agent.mjs"
```

## Testing

In test environments, configure a test API key to avoid starting the Node.js process:

```elixir
# config/test.exs
config :claude_code_ex,
  api_key: "test-key-not-used"
```

The PortServer detects this test key and runs in test mode without spawning Node.js.

## License

MIT
