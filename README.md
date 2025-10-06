# ClaudeCodeEx

An Elixir wrapper for the **@anthropic-ai/claude-agent-sdk**, providing a robust, concurrent, and fault-tolerant interface to build powerful AI agents.

This library enables Elixir applications to interact with Claude AI through a supervised Port-based communication channel with a Node.js process. It extends the core SDK with Elixir-native features like `GenServer`-based session management, custom tool definitions, and a first-class streaming API.

## Features

- **Stateful Conversations**: Manage multiple, concurrent conversations with remembered context using `GenServer`-backed processes.
- **Elixir-Defined Tools**: Define custom tools directly in your Elixir code and let Claude execute them.
- **Streaming API**: Consume agent events (`:text`, `:tool_use`, `:thinking`, etc.) effortlessly with Elixir's `Stream` module.
- **Supervised Node.js Process**: The underlying Node.js process is automatically managed by an Elixir supervisor, ensuring it restarts on failure.
- **Serializable Structs**: Core concepts like `Tool` and `Conversation` are represented by structs, making them easy to work with and integrate into your application (e.g., for database storage).

## Installation

Add `claude_code_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:claude_code_ex, "~> 0.2.0"}
  ]
end
```

## Prerequisites

- Node.js installed and available in `PATH`.
- An Anthropic API key.

## Configuration

Configure your API key in `config/config.exs`:

```elixir
config :claude_code_ex,
  api_key: System.get_env("ANTHROPIC_API_KEY")
```

## Usage

### Streaming API (Recommended)

The easiest way to interact with the agent is through the streaming API. This returns a `Stream` that you can process with standard `Enum` or `Stream` functions.

```elixir
{:ok, stream} = ClaudeCodeEx.stream_query("Write a short poem about Elixir.")

stream
|> Stream.filter(fn {type, _data} -> type == :text end)
|> Enum.each(fn {:text, chunk} -> IO.write(chunk) end)
# => "In code's embrace, a language bright,
#     Elixir flows with pure delight.
#     With OTP's strength, it stands so tall,
#     Answering concurrency's call."
```

The stream emits tuples of the form `{type, data}` for all agent events.

### Stateful Conversations

For ongoing dialogues, you can create a stateful conversation process.

```elixir
# Start a conversation with a system prompt
{:ok, conv_pid} = ClaudeCodeEx.start_conversation(system_prompt: "You are a helpful assistant.")

# Query the conversation
{:ok, query_id} = ClaudeCodeEx.query_conversation(conv_pid, "What is the capital of France?")

# Use the streaming API or receive messages manually
receive do
  {:agent_message, ^query_id, data} -> IO.inspect(data)
  # => %{"type" => "message", "content" => "The capital of France is Paris."}
end

# The conversation process remembers the context for the next query
{:ok, query_id_2} = ClaudeCodeEx.query_conversation(conv_pid, "What is its population?")
# ... receive messages for query_id_2 ...

# Stop the conversation process when done
ClaudeCodeEx.stop_conversation(conv_pid)
```

### Elixir-Defined Tools

You can define custom tools for the agent to use by creating `ClaudeCodeEx.Tool` structs.

```elixir
defmodule MyTools do
  def get_weather_tool do
    %ClaudeCodeEx.Tool{
      name: "get_current_weather",
      description: "Get the current weather for a specified location.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string", "description" => "The city and state, e.g., San Francisco, CA"}
        },
        "required" => ["location"]
      },
      implementation: fn %{"location" => location} ->
        # In a real app, you would call an external weather API here.
        "The weather in #{location} is 72°F and sunny."
      end
    }
  end
end

# Start a conversation with the tool
{:ok, conv_pid} = ClaudeCodeEx.start_conversation(tools: [MyTools.get_weather_tool()])

# Ask a question that requires the tool
{:ok, stream} = ClaudeCodeEx.stream_query(
  "What's the weather like in Boston?",
  tools: [MyTools.get_weather_tool()]
)

# You can observe the agent using the tool and then providing the final answer
Enum.to_list(stream)
# [
#   {:tool_use, %{tool: "get_current_weather", args: %{"location" => "Boston"}}},
#   {:tool_result, %{result: "The weather in Boston is 72°F and sunny."}},
#   {:message, %{... content: "The current weather in Boston is 72°F and sunny."}},
#   ...
# ]
```

## Architecture

```
Elixir Application
    ↓
ClaudeCodeEx (Public API)
    ↓
Conversation GenServer (Optional, for stateful sessions)
    ↓
PortServer (GenServer managing Node.js process)
    ↕ (stdio/JSON communication)
Node.js process (agent.js)
    ↓
@anthropic-ai/claude-agent-sdk
    ↓
Anthropic API
```

## License

MIT