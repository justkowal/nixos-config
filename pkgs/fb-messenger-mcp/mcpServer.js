#!/usr/bin/env node

import dotenv from "dotenv";
import express from "express";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import {
  CallToolRequestSchema,
  ErrorCode,
  ListToolsRequestSchema,
  McpError,
} from "@modelcontextprotocol/sdk/types.js";
import { discoverTools } from "./lib/tools.js";

import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

dotenv.config({ path: path.resolve(__dirname, ".env") });

const SERVER_NAME = "fb-messenger-mcp";

async function transformTools(tools) {
  return tools
    .map((tool) => {
      const definitionFunction = tool.definition?.function;
      if (!definitionFunction) return;
      return {
        name: definitionFunction.name,
        description: definitionFunction.description,
        inputSchema: definitionFunction.parameters,
      };
    })
    .filter(Boolean);
}

async function setupServerHandlers(server, tools) {
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: await transformTools(tools),
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const toolName = request.params.name;
    const tool = tools.find((t) => t.definition.function.name === toolName);
    if (!tool) {
      throw new McpError(ErrorCode.MethodNotFound, `Unknown tool: ${toolName}`);
    }
    const args = request.params.arguments || {};
    const requiredParameters =
      tool.definition?.function?.parameters?.required || [];
    for (const requiredParameter of requiredParameters) {
      if (!(requiredParameter in args)) {
        throw new McpError(
          ErrorCode.InvalidParams,
          `Missing required parameter: ${requiredParameter}`
        );
      }
    }
    try {
      const result = await tool.function(args);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(result, null, 2),
          },
        ],
      };
    } catch (error) {
      console.error("[Error] Failed to execute tool:", error);
      throw new McpError(
        ErrorCode.InternalError,
        `API error: ${error.message}`
      );
    }
  });
}

function checkAuth(req, res, next) {
  const expectedToken = process.env.MCP_TOKEN || process.env.AUTH_TOKEN;
  if (!expectedToken) {
    return next();
  }
  const auth = req.headers.authorization || "";
  const token = (auth.toLowerCase().startsWith("bearer ") ? auth.slice(7) : auth).trim();
  if (token !== expectedToken) {
    return res.status(401).json({
      jsonrpc: "2.0",
      error: { code: -32600, message: "Unauthorized" },
      id: null,
    });
  }
  next();
}

async function setupHttpServer(tools) {
  const app = express();
  app.use(express.json({ limit: "5mb" }));

  // Healthcheck endpoint (unauthenticated for container & proxy health checks)
  app.get(["/healthz", "/health", "/fbmcp/healthz", "/fbmcp/health"], (_req, res) => {
    res.status(200).send("ok");
  });

  // Normalize Accept header for clients (MCP spec requires both application/json and text/event-stream)
  app.use((req, res, next) => {
    if (req.method === "POST") {
      const accept = req.headers["accept"] || "";
      if (!accept.includes("application/json") || !accept.includes("text/event-stream")) {
        const normalized = "application/json, text/event-stream";
        req.headers["accept"] = normalized;
        let found = false;
        for (let i = 0; i < req.rawHeaders.length; i += 2) {
          if (req.rawHeaders[i].toLowerCase() === "accept") {
            req.rawHeaders[i + 1] = normalized;
            found = true;
            break;
          }
        }
        if (!found) {
          req.rawHeaders.push("Accept", normalized);
        }
      }
    }
    next();
  });

  // Streamable HTTP endpoints
  const handleStreamableHttp = async (req, res) => {
    try {
      const server = new Server(
        {
          name: SERVER_NAME,
          version: "1.0.0",
        },
        {
          capabilities: {
            tools: {},
          },
        }
      );
      server.onerror = (error) => console.error("[Error]", error);
      await setupServerHandlers(server, tools);

      const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: undefined,
      });

      res.on("close", async () => {
        await transport.close();
        await server.close();
      });

      await server.connect(transport);
      await transport.handleRequest(req, res, req.body);
    } catch (error) {
      console.error("Error handling MCP request:", error);
      if (!res.headersSent) {
        res.status(500).json({
          jsonrpc: "2.0",
          error: {
            code: -32603,
            message: "Internal server error",
          },
          id: null,
        });
      }
    }
  };

  const streamableRoutes = [
    "/mcp",
    "/fbmcp",
    "/fbmcp/mcp",
    "/",
  ];

  app.post(streamableRoutes, checkAuth, handleStreamableHttp);

  // SSE Transport support
  const transports = {};
  const servers = {};

  const handleSseGet = async (_req, res) => {
    const server = new Server(
      {
        name: SERVER_NAME,
        version: "1.0.0",
      },
      {
        capabilities: {
          tools: {},
        },
      }
    );
    server.onerror = (error) => console.error("[SSE Error]", error);
    await setupServerHandlers(server, tools);

    const transport = new SSEServerTransport("/messages", res);
    transports[transport.sessionId] = transport;
    servers[transport.sessionId] = server;

    res.on("close", async () => {
      delete transports[transport.sessionId];
      await server.close();
      delete servers[transport.sessionId];
    });

    await server.connect(transport);
  };

  const handleSsePost = async (req, res) => {
    const sessionId = req.query.sessionId;
    const transport = transports[sessionId];
    const server = servers[sessionId];

    if (transport && server) {
      await transport.handlePostMessage(req, res);
    } else {
      res.status(400).send("No transport/server found for sessionId");
    }
  };

  app.get(["/sse", "/fbmcp/sse"], checkAuth, handleSseGet);
  app.post(["/messages", "/fbmcp/messages"], checkAuth, handleSsePost);

  const port = process.env.PORT || 3001;
  app.listen(port, "0.0.0.0", () => {
    console.log(`[fb-messenger-mcp] HTTP Server listening on port ${port}`);
    console.log(`  Endpoints:`);
    console.log(`    POST /fbmcp`);
    console.log(`    POST /fbmcp/mcp`);
    console.log(`    POST /mcp`);
    console.log(`    GET  /healthz`);
  });
}

async function setupStdio(tools) {
  const server = new Server(
    {
      name: SERVER_NAME,
      version: "1.0.0",
    },
    {
      capabilities: {
        tools: {},
      },
    }
  );
  server.onerror = (error) => console.error("[Error]", error);
  await setupServerHandlers(server, tools);

  process.on("SIGINT", async () => {
    await server.close();
    process.exit(0);
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

async function run() {
  const args = process.argv.slice(2);
  const isHttp =
    args.includes("--streamable-http") ||
    args.includes("--sse") ||
    args.includes("--http") ||
    Boolean(process.env.PORT);

  const tools = await discoverTools();

  if (isHttp) {
    await setupHttpServer(tools);
  } else {
    await setupStdio(tools);
  }
}

run().catch(console.error);
