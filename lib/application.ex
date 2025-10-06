defmodule ClaudeCodeEx.Application do
  @moduledoc """
  OTP Application for ClaudeCodeEx.

  Automatically starts the supervision tree on boot, which includes
  the PortServer managing the Node.js process.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {ClaudeCodeEx.Supervisor, Application.get_all_env(:claude_code_ex)}
    ]

    opts = [strategy: :one_for_one, name: ClaudeCodeEx.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
