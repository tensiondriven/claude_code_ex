defmodule ClaudeCodeEx.Supervisor do
  @moduledoc """
  Supervisor for ClaudeCodeEx components.

  Manages the PortServer child process using a `:one_for_one` strategy,
  ensuring the Node.js bridge is automatically restarted if it crashes.

  Started automatically by `ClaudeCodeEx.Application` on boot with
  configuration from `Application.get_all_env(:claude_code_ex)`.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {ClaudeCodeEx.PortServer, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
