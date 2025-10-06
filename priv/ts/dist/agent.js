const { Agent } = require("@anthropic-ai/claude-agent-sdk");
const readline = require("readline");

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false,
});

const activeAgents = new Map();

rl.on("line", async (line) => {
  try {
    const request = JSON.parse(line);
    const { type, query_id, prompt, options, tool_use_id, result } = request;

    if (type === "ping") {
      process.stdout.write(
        JSON.stringify({ type: "pong", query_id }) + "\n"
      );
      return;
    }

    // Handle a tool result sent back from Elixir
    if (type === "tool_result") {
      const agent = activeAgents.get(query_id);
      if (agent) {
        // Continue the agent's run by providing the tool result.
        // The SDK is expected to handle this to continue the generation.
        await agent.run({ tool_result: { tool_use_id, result } });
      }
      return;
    }

    if (type !== "query") {
      throw new Error(`Unknown request type: ${type}`);
    }

    const agent = new Agent({
      model: options.model || "claude-3-opus-20240229",
      systemPrompt: options.system_prompt,
      tools: options.tools || [],
    });
    activeAgents.set(query_id, agent);

    const send = (data) => {
      process.stdout.write(JSON.stringify({ query_id, ...data }) + "\n");
    };

    agent.on("text", (text) => send({ type: "text", text }));
    agent.on("thinking", (thinking) => send({ type: "thinking", thinking }));
    agent.on("tool_use", ({ toolName, input, toolUseId }) =>
      send({ type: "tool_use", tool: toolName, args: input, tool_use_id: toolUseId })
    );
    agent.on("tool_result", ({ toolUseId, result }) =>
      send({ type: "tool_result", tool_use_id: toolUseId, result })
    );
    agent.on("message", (data) => send({ type: "message", data }));

    agent.on("done", () => {
      send({ type: "done" });
      activeAgents.delete(query_id);
    });
    agent.on("error", (error) => {
      send({ type: "error", error: error.message });
      activeAgents.delete(query_id);
    });

    await agent.run({
      prompt,
      workingDir: options.working_dir,
    });

  } catch (error) {
    const query_id = (line.match(/"query_id":"(.*?)"/) || [])[1] || "unknown";
    process.stdout.write(
      JSON.stringify({ type: "error", query_id, error: error.message }) + "\n"
    );
  }
});