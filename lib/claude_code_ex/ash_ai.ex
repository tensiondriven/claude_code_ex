defmodule ClaudeCodeEx.AshAi do
  @moduledoc """
  Integration layer for exposing AshAi tools to ClaudeCodeEx agents.

  This module translates AshAi's Ash-backed tools into Claude Code SDK custom tools,
  allowing Claude agents to call your Ash actions directly.

  ## Usage

  ```elixir
  # In a query
  {:ok, response} = ClaudeCodeEx.query(
    "Create a blog post about Elixir patterns",
    ash_tools: [otp_app: :my_app]
  )

  # Or with specific domains
  {:ok, response} = ClaudeCodeEx.query(
    "List all users and their posts",
    ash_tools: [domains: [MyApp.Blog, MyApp.Accounts]]
  )
  ```

  ## How It Works

  1. Discovers AshAi tools from your configured domains
  2. Converts them to Claude Code SDK custom tool format
  3. Registers them with the agent for the query
  4. Routes tool calls back to Elixir to execute Ash actions
  5. Returns results to Claude

  ## Requirements

  - `ash_ai` must be added to your dependencies
  - Tools must be defined in your Ash domains using `AshAi.tools/1`

  Example domain:

  ```elixir
  defmodule MyApp.Blog do
    use Ash.Domain, extensions: [AshAi]

    tools do
      tool :list_posts, MyApp.Blog.Post, :read
      tool :create_post, MyApp.Blog.Post, :create
    end
  end
  ```
  """

  require Logger

  @doc """
  Converts AshAi tool definitions to Claude Code SDK custom tool format.

  ## Options

  - `:otp_app` - Discovers all domains with AshAi tools in your application
  - `:domains` - List of specific domains to extract tools from
  - `:actor` - Actor to use when executing Ash actions
  - `:tenant` - Tenant context for multi-tenant applications

  ## Returns

  A list of custom tool definitions ready for the Claude Code SDK.
  """
  @spec convert_ash_tools(keyword()) :: {:ok, list(map())} | {:error, term()}
  def convert_ash_tools(opts \\ []) do
    with {:ok, ash_tools} <- discover_ash_tools(opts) do
      custom_tools =
        ash_tools
        |> Enum.map(&convert_tool(&1, opts))

      {:ok, custom_tools}
    end
  end

  ## Private Functions

  defp discover_ash_tools(opts) do
    cond do
      otp_app = Keyword.get(opts, :otp_app) ->
        discover_from_app(otp_app)

      domains = Keyword.get(opts, :domains) ->
        discover_from_domains(domains)

      true ->
        {:error, :no_discovery_method}
    end
  end

  defp discover_from_app(otp_app) do
    # Use AshAi.exposed_tools/1 to get all tools
    case Code.ensure_loaded?(AshAi) do
      true ->
        tools = AshAi.exposed_tools(otp_app: otp_app)
        {:ok, tools}

      false ->
        {:error, :ash_ai_not_loaded}
    end
  rescue
    e ->
      Logger.error("Failed to discover AshAi tools: #{inspect(e)}")
      {:error, {:discovery_failed, e}}
  end

  defp discover_from_domains(domains) do
    # Extract tools from specific domains
    case Code.ensure_loaded?(AshAi) do
      true ->
        tools =
          domains
          |> Enum.flat_map(fn domain ->
            # Get tools defined in the domain
            case Spark.Dsl.Extension.get_entities(domain, [:tools]) do
              {:ok, entities} -> entities
              _ -> []
            end
          end)

        {:ok, tools}

      false ->
        {:error, :ash_ai_not_loaded}
    end
  rescue
    e ->
      Logger.error("Failed to extract tools from domains: #{inspect(e)}")
      {:error, {:extraction_failed, e}}
  end

  defp convert_tool(tool, opts) do
    actor = Keyword.get(opts, :actor)
    tenant = Keyword.get(opts, :tenant)

    # Build the tool definition for Claude Code SDK
    %{
      name: to_string(tool.name),
      description: tool.description || build_description(tool),
      input_schema: build_input_schema(tool),
      function: build_executor(tool, actor, tenant)
    }
  end

  defp build_description(tool) do
    "Execute the #{tool.action} action on #{inspect(tool.resource)}"
  end

  defp build_input_schema(tool) do
    # Get the action from the resource
    ash_action = Ash.Resource.Info.action(tool.resource, tool.action)

    # Build JSON schema from action arguments
    properties =
      ash_action.arguments
      |> Enum.filter(& &1.public?)
      |> Enum.map(fn arg ->
        {to_string(arg.name), argument_to_schema(arg)}
      end)
      |> Map.new()

    required =
      ash_action.arguments
      |> Enum.filter(&(!&1.allow_nil?))
      |> Enum.map(&to_string(&1.name))

    %{
      type: "object",
      properties: properties,
      required: required
    }
  end

  defp argument_to_schema(arg) do
    base = %{
      type: ash_type_to_json_type(arg.type),
      description: arg.description || "The #{arg.name} argument"
    }

    # Add constraints if present
    case arg.constraints do
      nil -> base
      constraints -> Map.merge(base, constraints_to_schema(constraints))
    end
  end

  defp ash_type_to_json_type(:string), do: "string"
  defp ash_type_to_json_type(:integer), do: "integer"
  defp ash_type_to_json_type(:boolean), do: "boolean"
  defp ash_type_to_json_type(:uuid), do: "string"
  defp ash_type_to_json_type(:atom), do: "string"
  defp ash_type_to_json_type(:map), do: "object"
  defp ash_type_to_json_type({:array, _}), do: "array"
  defp ash_type_to_json_type(_), do: "string"

  defp constraints_to_schema(constraints) do
    schema = %{}

    schema =
      if min = Keyword.get(constraints, :min) do
        Map.put(schema, :minimum, min)
      else
        schema
      end

    schema =
      if max = Keyword.get(constraints, :max) do
        Map.put(schema, :maximum, max)
      else
        schema
      end

    schema =
      if one_of = Keyword.get(constraints, :one_of) do
        Map.put(schema, :enum, one_of)
      else
        schema
      end

    schema
  end

  defp build_executor(tool, actor, tenant) do
    fn arguments ->
      execute_ash_action(tool, arguments, actor, tenant)
    end
  end

  defp execute_ash_action(tool, arguments, actor, tenant) do
    # Convert string keys to atoms
    args =
      arguments
      |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)

    # Build the query/changeset
    case tool.action.type do
      :read ->
        execute_read(tool, args, actor, tenant)

      :create ->
        execute_create(tool, args, actor, tenant)

      :update ->
        execute_update(tool, args, actor, tenant)

      :destroy ->
        execute_destroy(tool, args, actor, tenant)

      type ->
        {:error, "Unsupported action type: #{type}"}
    end
  rescue
    e ->
      Logger.error("Failed to execute Ash action: #{inspect(e)}")
      {:error, Exception.message(e)}
  end

  defp execute_read(tool, args, actor, tenant) do
    tool.resource
    |> Ash.Query.for_read(tool.action.name, args, actor: actor, tenant: tenant)
    |> then(fn query ->
      if tool.load && tool.load != [] do
        Ash.Query.load(query, tool.load)
      else
        query
      end
    end)
    |> Ash.read()
    |> format_result()
  end

  defp execute_create(tool, args, actor, tenant) do
    tool.resource
    |> Ash.Changeset.for_create(tool.action.name, args, actor: actor, tenant: tenant)
    |> Ash.create()
    |> format_result()
  end

  defp execute_update(tool, args, actor, tenant) do
    # For updates, we need to get the record first
    # This assumes an `id` or identity is provided
    with {:ok, record} <- get_record_for_update(tool, args, actor, tenant) do
      record
      |> Ash.Changeset.for_update(tool.action.name, args, actor: actor, tenant: tenant)
      |> Ash.update()
      |> format_result()
    end
  end

  defp execute_destroy(tool, args, actor, tenant) do
    with {:ok, record} <- get_record_for_update(tool, args, actor, tenant) do
      record
      |> Ash.Changeset.for_destroy(tool.action.name, args, actor: actor, tenant: tenant)
      |> Ash.destroy()
      |> format_result()
    end
  end

  defp get_record_for_update(tool, args, actor, tenant) do
    # Try to find by identity or primary key
    cond do
      id = Map.get(args, :id) ->
        tool.resource
        |> Ash.get!(id, actor: actor, tenant: tenant)
        |> case do
          nil -> {:error, "Record not found"}
          record -> {:ok, record}
        end

      tool.identity ->
        # Use the configured identity
        identity_fields = Ash.Resource.Info.identity(tool.resource, tool.identity).keys

        identity_values =
          identity_fields
          |> Enum.map(&{&1, Map.get(args, &1)})
          |> Map.new()

        tool.resource
        |> Ash.get_by!(identity_values, actor: actor, tenant: tenant)
        |> case do
          nil -> {:error, "Record not found"}
          record -> {:ok, record}
        end

      true ->
        {:error, "No identity or id provided for update/destroy"}
    end
  end

  defp format_result({:ok, result}) when is_list(result) do
    # For read actions that return lists
    json_safe_result =
      result
      |> Enum.map(&to_json_safe/1)

    {:ok, Jason.encode!(json_safe_result)}
  end

  defp format_result({:ok, result}) do
    # For create/update/destroy
    {:ok, Jason.encode!(to_json_safe(result))}
  end

  defp format_result({:error, error}) do
    {:error, format_error(error)}
  end

  defp to_json_safe(%_{} = struct) do
    # Convert struct to map, only include public attributes
    resource = struct.__struct__

    struct
    |> Map.from_struct()
    |> Enum.filter(fn {key, _value} ->
      # Check if attribute is public
      case Ash.Resource.Info.attribute(resource, key) do
        nil -> false
        attr -> attr.public?
      end
    end)
    |> Map.new()
  end

  defp to_json_safe(value), do: value

  defp format_error(error) do
    cond do
      is_binary(error) ->
        error

      is_exception(error) ->
        Exception.message(error)

      is_map(error) and Map.has_key?(error, :__struct__) ->
        # Try to format as Ash error
        try do
          error
          |> Ash.Error.to_error_class()
          |> Map.get(:errors, [])
          |> Enum.map_join(", ", &Exception.message/1)
        rescue
          _ -> inspect(error)
        end

      true ->
        inspect(error)
    end
  end
end
