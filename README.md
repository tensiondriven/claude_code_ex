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

## Advanced Configuration

```elixir
config :claude_code_ex,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  node_path: "/custom/path/to/node",
  agent_script: "/custom/path/to/agent.mjs",
  base_url: "https://custom-api-endpoint.com"  # Optional proxy/custom endpoint
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
