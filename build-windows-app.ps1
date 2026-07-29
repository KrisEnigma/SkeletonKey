# Publishes the Windows listener as a single standalone .exe you can just
# double-click, no dotnet CLI, no console window, no terminal needed after
# this point. Run this script once from PowerShell whenever you change
# windows-injector's code; the result is a normal double-clickable app.

$ErrorActionPreference = "Stop"

$projectPath = Join-Path $PSScriptRoot "windows-injector\WindowsInjector.csproj"
$outputPath = Join-Path $PSScriptRoot "windows-injector\publish"

# Explicit -p:SelfContained=false (an MSBuild property, not just the CLI
# --self-contained switch) to make sure this doesn't silently bundle the
# whole .NET + WinForms runtime into the exe (that's what balloons it to
# 100MB+). This machine already has the .NET SDK (you've been running
# `dotnet run` on it), so it has the matching Desktop Runtime too, no need
# to bundle another copy. If you ever want to run this on a PC without .NET
# installed, change SelfContained to true instead (expect ~60-100MB+).
dotnet publish $projectPath `
  -c Release `
  -p:RuntimeIdentifier=win-x64 `
  -p:SelfContained=false `
  -p:PublishSingleFile=true `
  -o $outputPath

Write-Host ""
Write-Host "Published: $outputPath\SkeletonKey.exe"
Write-Host "Double-click it directly from now on - no dotnet/console needed."
Write-Host "Tip: right-click it -> Send to -> Desktop (create shortcut), or"
Write-Host "drop a shortcut in shell:startup to have it launch automatically"
Write-Host "when you log in."
