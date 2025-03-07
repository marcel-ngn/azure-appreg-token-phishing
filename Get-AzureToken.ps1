#Requires -Version 6.0

param(
    [Parameter(Mandatory=$true)]
    [string]$ClientId,
    
    [Parameter(Mandatory=$true)]
    [string]$TenantId,
    
    [Parameter(Mandatory=$false)]
    [int]$Port = 8000,
    
    [Parameter(Mandatory=$false)]
    [string]$Scope = "https://graph.microsoft.com/.default"
)

# Import required module for web server
Add-Type -AssemblyName System.Net.HttpListener

# Configuration
$redirectUri = [System.Uri]::EscapeDataString("http://localhost:$Port")
$scopeEncoded = [System.Uri]::EscapeDataString($Scope)
$authEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize"

# Generate authorization URL - properly escaped for macOS
$authUrl = "$authEndpoint`?client_id=$ClientId&response_type=token&redirect_uri=$redirectUri&scope=$scopeEncoded&response_mode=fragment"

# HTML template to display after successful authentication and extract token
$successHtml = @"
<!DOCTYPE html>
<html>
<head>
    <title>Authentication Successful</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
        .success { color: green; font-size: 24px; margin-bottom: 20px; }
    </style>
    <script>
        // Extract token from URL fragment
        window.onload = function() {
            const fragment = window.location.hash.substring(1);
            const params = new URLSearchParams(fragment);
            const token = params.get('access_token');
            
            if (token) {
                // Create a URL with the token in query params for the server to process
                window.location.href = '/token?access_token=' + encodeURIComponent(token);
            } else {
                document.getElementById('message').innerText = 'No token found in redirect URL.';
                document.getElementById('message').style.color = 'red';
            }
        }
    </script>
</head>
<body>
    <div class="success">Authentication Successful!</div>
    <p id="message">Processing token...</p>
</body>
</html>
"@

# Create a handler for the HTTP server
$tokenReceived = $false
$accessToken = ""

# Start HTTP Server
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try {
    $listener.Start()
}
catch {
    Write-Host "Error starting HTTP listener. Make sure port $Port is available and you have permissions." -ForegroundColor Red
    Write-Host "Error details: $_"
    exit 1
}

Write-Host "Starting authentication flow..." -ForegroundColor Cyan
Write-Host "Listening on port $Port"

# MANUAL APPROACH: Just provide the URL for manual copying
Write-Host "Please copy and paste this URL into your browser:" -ForegroundColor Yellow
Write-Host $authUrl -ForegroundColor Green

Write-Host "Waiting for authentication to complete..." -ForegroundColor Yellow

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        
        # Prepare response
        $buffer = [System.Text.Encoding]::UTF8.GetBytes("")
        
        # Handle routes
        if ($request.HttpMethod -eq "GET" -and $request.Url.LocalPath -eq "/") {
            # Serve HTML page
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($successHtml)
            $response.ContentType = "text/html"
        }
        elseif ($request.HttpMethod -eq "GET" -and $request.Url.LocalPath -eq "/token") {
            # Process query parameters to extract token
            $accessToken = $request.QueryString["access_token"]
            
            # Serve confirmation page
            $confirmationHtml = "<html><body><h1>Token received successfully!</h1><p>You can close this window now.</p></body></html>"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($confirmationHtml)
            $response.ContentType = "text/html"
            
            $tokenReceived = $true
        }
        
        # Send response
        $response.ContentLength64 = $buffer.Length
        $response.OutputStream.Write($buffer, 0, $buffer.Length)
        $response.OutputStream.Close()
        
        # Exit loop if token was received
        if ($tokenReceived) {
            break
        }
    }
}
catch {
    Write-Host "Error in HTTP listener: $_" -ForegroundColor Red
}
finally {
    # Stop the HTTP listener
    $listener.Stop()
}

if ($tokenReceived) {
    Write-Host "`nAUTHENTICATION SUCCESSFUL!" -ForegroundColor Green
    Write-Host "`nACCESS TOKEN:" -ForegroundColor Cyan
    Write-Host $accessToken
    
    # Try to decode and display token info if possible
    try {
        # Split the token and get the payload part
        $tokenParts = $accessToken.Split(".")
        if ($tokenParts.Length -ge 2) {
            # Base64 decode (need to add padding and handle URL encoding)
            $payloadBase64 = $tokenParts[1].Replace('-', '+').Replace('_', '/')
            
            # Add padding if needed
            switch ($payloadBase64.Length % 4) {
                0 { break }
                2 { $payloadBase64 += "==" }
                3 { $payloadBase64 += "=" }
            }
            
            $decodedBytes = [System.Convert]::FromBase64String($payloadBase64)
            $decodedText = [System.Text.Encoding]::UTF8.GetString($decodedBytes)
            $tokenInfo = $decodedText | ConvertFrom-Json
            
            Write-Host "`nTOKEN INFORMATION:" -ForegroundColor Blue
            if ($tokenInfo.sub) { Write-Host "Subject: $($tokenInfo.sub)" }
            if ($tokenInfo.name) { Write-Host "Name: $($tokenInfo.name)" }
            if ($tokenInfo.iat) { Write-Host "Issued at: $($tokenInfo.iat)" }
            if ($tokenInfo.exp) { Write-Host "Expires: $($tokenInfo.exp)" }
            if ($tokenInfo.iss) { Write-Host "Issuer: $($tokenInfo.iss)" }
            
            # Print scopes
            if ($tokenInfo.scp) {
                Write-Host "Scopes: $($tokenInfo.scp)"
            }
        }
    }
    catch {
        Write-Host "`nCould not decode token: $_" -ForegroundColor Yellow
    }
    
    # Return the token so it can be used in other scripts
    return $accessToken
}
else {
    Write-Host "Authentication failed or was canceled." -ForegroundColor Red
}
