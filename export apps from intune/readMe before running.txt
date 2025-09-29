# README – Before Running `exportApps.ps1`

This script exports Intune mobile apps and assignments to an Excel file using Microsoft Graph API.

---

## Prerequisites

1. **Create a Client Secret**  
   - Go to **Azure Portal** → **Entra ID** → **App registrations** → select your app.  
   - Navigate to **Certificates & secrets** → **New client secret**.  
   - Copy the **Value** (this is your client secret).

2. **Set the Client Secret as an environment variable** (in the current PowerShell session):  
   ```powershell
   $env:GRAPH_CLIENT_SECRET = "Your-Client-Secret-Value"


Usage

Run the script with the following parameters:

.\exportApps.ps1 -AuthMode AppSecret `
  -TenantId "Directory (tenant) ID" `
  -ClientId "Application (client) ID" `
  -UseBeta


TenantId → Your tenant ID (GUID)

ClientId → Application (client) ID of your registered app.

-UseBeta → Uses the Graph beta endpoint.



Output

The script generates an Excel file:

Intune_Apps_Assignments.xlsx on your documents folder