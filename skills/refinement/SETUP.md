# Azure DevOps MCP Server Setup

This skill requires the **Azure DevOps MCP server**. If a DevOps tool call fails with a connection or "not found" error, share these instructions with the user:

## Installation

1. Install the MCP server package:
   ```
   npm install -g @anthropic/azure-devops-mcp
   ```

2. Add the server to your Claude Code MCP configuration (`~/.claude/settings.json` or project `.claude/settings.json`):
   ```json
   {
     "mcpServers": {
       "azure-devops": {
         "command": "npx",
         "args": ["-y", "@anthropic/azure-devops-mcp"],
         "env": {
           "AZURE_DEVOPS_ORG": "<your-org-name>",
           "AZURE_DEVOPS_PAT": "<your-personal-access-token>"
         }
       }
     }
   }
   ```

3. Generate a Personal Access Token (PAT) at `https://dev.azure.com/<your-org>/_usersSettings/tokens` with these scopes:
   - **Work Items:** Read & Write
   - **Code:** Read

4. Restart Claude Code after configuring.
