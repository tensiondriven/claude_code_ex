import { Agent, ToolDefinition } from "@anthropic-ai/claude-agent-sdk";
import * as readline from "readline";

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false,
});

// A map to keep track of active agent instances per query
const activeAgents = new Map<string, Agent>();

rl.on("line", async (line) => {
  try {
    const request = JSON.parse(line);
    const { type, query_id, prompt, options } = request;

    if (type === "ping") {
      process.stdout.write(
        JSON.stringify({ type: "pong", query_id }) + "\n"
      );
      return;
    }

    if (type !== "query") {
      throw new Error(`Unknown request type: ${type}`);
    }

    // Create a new agent for this query
    const agent = new Agent({
      model: options.model || "claude-3-opus-20240229",
      systemPrompt: options.system_prompt,
      tools: (options.tools as ToolDefinition[]) || [],
    });
    activeAgents.set(query_id, agent);

    // Helper to send JSON responses
    const send = (data: object) => {
      process.stdout.write(JSON.stringify({ query_id, ...data }) + "\n");
    };

    // Attach event listeners
    agent.on("text", (text) => send({ type: "text", text }));
    agent.on("thinking", (thinking) => send({ type: "thinking", thinking }));
    agent.on("tool_use", ({ toolName, input, toolUseId }) =>
      send({ type: "tool_use", tool: toolName, args: input, tool_use_id: toolUseId })
    );
    agent.on("tool_result", ({ toolUseId, result }) =>
      send({ type: "tool_result", tool_use_id: toolUseId, result })
    );
    agent.on("message", (data) => send({ type: "message", data }));

    // Handle completion and errors
    agent.on("done", () => {
      send({ type: "done" });
      activeAgents.delete(query_id);
    });
    agent.on("error", (error) => {
      send({ type: "error", error: error.message });
      activeAgents.delete(query_id);
    });

    // Start the agent run
    await agent.run({
      prompt,
      workingDir: options.working_dir,
    });

  } catch (error) {
    const query_id = (line.match(/"query_id":"(.*?)"/) || [])[1] || "unknown";
    process.stdout.write(
      JSON.stringify({ type: "error", query_id, error: (error as Error).message }) + "\n"
    );
  }
});