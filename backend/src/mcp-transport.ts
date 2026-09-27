import { StreamableHTTPTransport } from '@hono/mcp'
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { SUPPORTED_PROTOCOL_VERSIONS } from '@modelcontextprotocol/sdk/types.js'
import type { Context } from 'hono'
import { HTTPException } from 'hono/http-exception'

/** One stateless transport per authenticated request. */
export async function handleMcpRequest(c: Context, server: McpServer): Promise<Response> {
  const transport = new StreamableHTTPTransport()
  await server.connect(transport)
  try {
    const response = await transport.handleRequest(c)
    if (!response) throw new Error('MCP transport returned no response')
    return response
  } catch (error) {
    const version = c.req.header('mcp-protocol-version')
    if (error instanceof HTTPException && error.status === 404 && version && !SUPPORTED_PROTOCOL_VERSIONS.includes(version)) {
      // @hono/mcp 0.3 returns 404 for unsupported versions. Modern clients need
      // legacy 400 to fall back to initialize; do not pretend to speak 2026 MCP.
      // Initialization itself still reaches the SDK's version negotiation.
      // https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#backward-compatibility
      const response = error.getResponse()
      return new Response(response.body, { status: 400, headers: response.headers })
    }
    throw error
  }
}
