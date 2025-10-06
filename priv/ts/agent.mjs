#!/usr/bin/env node

/**
 * Claude Agent SDK 2.0 Wrapper - Stdio Bridge for Elixir
 *
 * This wrapper provides a stdio-based interface to the Claude Agent SDK 2.0,
 * allowing Elixir processes to communicate with the agentic capabilities
 * of Claude Code.
 *
 * Protocol:
 * - Reads newline-delimited JSON requests from stdin
 * - Writes newline-delimited JSON responses to stdout
 * - Stderr is used for logging/debugging
 *
 * Request format:
 * {
 *   "query_id": "uuid",
 *   "type": "query",
 *   "prompt": "string",
 *   "options": {
 *     "workingDir": "/path",
 *     "tools": ["filesystem", "web_search"],
 *     ...
 *   }
 * }
 *
 * Response formats:
 * - Message chunk: {"type": "message", "query_id": "uuid", "data": {...}}
 * - Tool use: {"type": "tool_use", "query_id": "uuid", "tool": "name", "args": {...}}
 * - Done: {"type": "done", "query_id": "uuid", "result": "..."}
 * - Error: {"type": "error", "query_id": "uuid", "error": "message"}
 */

import { query } from '@anthropic-ai/claude-code';
import { createInterface } from 'readline';

const rl = createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false
});

/**
 * Send a response back to Elixir via stdout
 */
function sendResponse(response) {
  process.stdout.write(JSON.stringify(response) + '\n');
}

/**
 * Log to stderr (won't interfere with stdio protocol)
 */
function log(message, data = null) {
  const timestamp = new Date().toISOString();
  const logLine = data
    ? `[${timestamp}] ${message}: ${JSON.stringify(data)}`
    : `[${timestamp}] ${message}`;
  process.stderr.write(logLine + '\n');
}

/**
 * Process a query request from Elixir
 */
async function processQuery(request) {
  const { query_id, prompt, options = {} } = request;

  log('Processing query', { query_id, prompt: prompt.substring(0, 100) });

  try {
    // Build SDK options
    const sdkOptions = {
      workingDir: options.working_dir || process.cwd(),
      systemPrompt: options.system_prompt,
      ...options
    };

    // Add model if specified (for GLM-4.5, GLM-4.6, etc.)
    if (options.model) {
      sdkOptions.model = options.model;
    }

    log('SDK Options', sdkOptions);

    // Create the query with SDK 2.0
    const queryStream = query({
      prompt,
      options: sdkOptions
    });

    // Stream responses back to Elixir
    for await (const message of queryStream) {
      // Always send the full message
      sendResponse({
        type: 'message',
        query_id,
        data: message
      });

      // Emit specific events based on message type for easier UI integration
      if (message.type === 'assistant' && message.content) {
        for (const block of message.content) {
          // Tool use event
          if (block.type === 'tool_use') {
            sendResponse({
              type: 'tool_use',
              query_id,
              tool: block.name,
              args: block.input,
              tool_use_id: block.id
            });
          }

          // Text response event
          if (block.type === 'text') {
            sendResponse({
              type: 'text',
              query_id,
              text: block.text
            });
          }

          // Thinking block event (extended thinking)
          if (block.type === 'thinking') {
            sendResponse({
              type: 'thinking',
              query_id,
              thinking: block.thinking
            });
          }
        }
      }

      // Tool result event
      if (message.type === 'result') {
        sendResponse({
          type: 'tool_result',
          query_id,
          tool_use_id: message.parent_tool_use_id,
          result: message.message
        });
      }

      // Partial assistant message (streaming)
      if (message.type === 'partial_assistant') {
        sendResponse({
          type: 'partial_message',
          query_id,
          delta: message
        });
      }

      // System messages (permissions, etc.)
      if (message.type === 'system') {
        sendResponse({
          type: 'system',
          query_id,
          system_message: message.message
        });
      }
    }

    // Query complete
    sendResponse({
      type: 'done',
      query_id
    });

    log('Query completed', { query_id });

  } catch (error) {
    log('Query error', { query_id, error: error.message });

    sendResponse({
      type: 'error',
      query_id,
      error: error.message,
      stack: error.stack
    });
  }
}

/**
 * Main loop - read requests from stdin
 */
log('Claude Agent SDK wrapper started');
log('SDK Version', require('./node_modules/@anthropic-ai/claude-code/package.json').version);

rl.on('line', async (line) => {
  try {
    const request = JSON.parse(line);

    if (request.type === 'query') {
      await processQuery(request);
    } else if (request.type === 'ping') {
      sendResponse({ type: 'pong', timestamp: Date.now() });
    } else {
      log('Unknown request type', { type: request.type });
      sendResponse({
        type: 'error',
        error: `Unknown request type: ${request.type}`
      });
    }
  } catch (error) {
    log('Failed to parse request', { line, error: error.message });
    sendResponse({
      type: 'error',
      error: 'Invalid JSON request'
    });
  }
});

rl.on('close', () => {
  log('Stdin closed, exiting');
  process.exit(0);
});

process.on('SIGINT', () => {
  log('Received SIGINT, exiting');
  process.exit(0);
});

process.on('SIGTERM', () => {
  log('Received SIGTERM, exiting');
  process.exit(0);
});
