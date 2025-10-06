defmodule ClaudeCodeExTest do
  use ExUnit.Case
  doctest ClaudeCodeEx

  test "application starts in test mode" do
    assert Process.whereis(ClaudeCodeEx.PortServer) != nil
  end

  test "ping returns pong in test mode" do
    assert :pong = ClaudeCodeEx.PortServer.ping()
  end

  test "query returns error in test mode" do
    assert {:error, :test_mode} = ClaudeCodeEx.PortServer.query("test")
  end
end
