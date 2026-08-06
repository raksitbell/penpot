# Idempotent setup script for Windows.
# Creates .env from .env.example and auto-generates PENPOT_SECRET_KEY
# and POSTGRES_PASSWORD. Won't overwrite an existing .env.
#
# Usage (from repo root, PowerShell):
#   .\scripts\setup.ps1

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root ".env"
$exampleFile = Join-Path $root ".env.example"

if (Test-Path $envFile) {
    Write-Host ".env already exists - not overwriting. Delete it first if you want to regenerate secrets." -ForegroundColor Yellow
    exit 0
}

if (-not (Test-Path $exampleFile)) {
    Write-Error ".env.example not found at $exampleFile"
}

Copy-Item $exampleFile $envFile

function New-UrlSafeSecret {
    param([int]$Bytes = 64)
    $buffer = New-Object byte[] $Bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    $b64 = [Convert]::ToBase64String($buffer)
    return $b64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-AlnumPassword {
    param([int]$Length = 32)
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $buffer = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    -join ($buffer | ForEach-Object { $chars[$_ % $chars.Length] })
}

$secretKey = New-UrlSafeSecret
$pgPassword = New-AlnumPassword

(Get-Content $envFile) | ForEach-Object {
    $_ -replace '^PENPOT_SECRET_KEY=.*', "PENPOT_SECRET_KEY=$secretKey" `
       -replace '^POSTGRES_PASSWORD=.*', "POSTGRES_PASSWORD=$pgPassword"
} | Set-Content $envFile

Write-Host "Created .env with a generated PENPOT_SECRET_KEY and POSTGRES_PASSWORD." -ForegroundColor Green
Write-Host "Still fill in manually: PENPOT_PUBLIC_URI, RESEND_API_KEY, SMTP_FROM_EMAIL" -ForegroundColor Yellow
