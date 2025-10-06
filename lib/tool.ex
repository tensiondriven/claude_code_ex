defmodule ClaudeCodeEx.Tool do
  @moduledoc """
  Defines a tool that can be used by the Claude agent.

  A tool consists of a name, a description for the AI, a schema for its
  arguments, and an Elixir function that implements its logic. This struct
  provides a clear, serializable-friendly way to define tools.

  ## Serialization

  The `:implementation` field holds an anonymous function and is therefore not
  directly serializable to a database. For persistence, it is recommended to
  store the tool's identity (e.g., as `{MyModule, :function_name, [static_args]}`)
  and reconstruct the `ClaudeCodeEx.Tool` struct at runtime.

  ## Example

      defmodule MyCalculator do
        def add(a, b), do: a + b
      end

      add_tool = %ClaudeCodeEx.Tool{
        name: "add",
        description: "Adds two numbers and returns the sum.",
        input_schema: %{
          type: "object",
          properties: %{
            "a" => %{"type" => "number"},
            "b" => %{"type" => "number"}
          },
          required: ["a", "b"]
        },
        implementation: fn %{"a" => a, "b" => b} -> MyCalculator.add(a, b) end
      }
  """

  @enforce_keys [:name, :description, :input_schema, :implementation]
  defstruct [:name, :description, :input_schema, :implementation]

  @type t :: %__MODULE__{
          name: String.t() | atom(),
          description: String.t(),
          input_schema: map(),
          implementation: (map() -> any())
        }
end