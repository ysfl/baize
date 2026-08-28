param(
  [ValidateSet('zh', 'en')][string]$Lang = 'zh',
  [ValidateSet('auto', 'manual', 'codex', 'claude', 'zcode', 'gemini', 'qwen', 'cursor', 'windsurf', 'vscode', 'cline', 'trae')][string]$Client = 'auto',
  [string]$SkillDir = '',
  [ValidatePattern('^(latest|[0-9]+\.[0-9]+\.[0-9]+)$')][string]$McpVersion = 'latest',
  [switch]$SkipMcp,
  [switch]$SkipSkill,
  [switch]$Help
)

$ErrorActionPreference = 'Stop'
$repo = 'ysfl/baize-mcp'
$userHome = [Environment]::GetFolderPath('UserProfile')
$mcpBinDir = if ($env:BAIZE_AI_BIN_DIR) { $env:BAIZE_AI_BIN_DIR } else { Join-Path $env:LOCALAPPDATA 'Baize\bin' }
$repoRoot = Split-Path -Parent $PSScriptRoot
$skillSourceDir = Join-Path $repoRoot 'skills\baize-ai'

function Say([string]$Zh, [string]$En) { if ($Lang -eq 'en') { Write-Host $En } else { Write-Host $Zh } }
function Fail([string]$Message) { throw $Message }

if ($Help) {
  Write-Host 'Baize AI access installer (installs MCP and Skill only; does not install Baize).'
  Write-Host 'Usage: .\install-ai-access.ps1 [-Lang zh|en] [-Client auto|manual|codex|claude|zcode|gemini|qwen|cursor|windsurf|vscode|cline|trae] [-SkillDir path] [-McpVersion latest|x.y.z] [-SkipMcp] [-SkipSkill]'
  exit 0
}

function Get-ReleaseMetadata {
  $uri = if ($McpVersion -eq 'latest') { "https://api.github.com/repos/$repo/releases/latest" } else { "https://api.github.com/repos/$repo/releases/tags/v$McpVersion" }
  return Invoke-RestMethod -Headers @{ Accept = 'application/vnd.github+json' } -Uri $uri
}

function Install-Mcp {
  $metadata = Get-ReleaseMetadata
  $version = $metadata.tag_name.TrimStart('v')
  $nativeArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
  $arch = switch ($nativeArch.ToUpperInvariant()) {
    'ARM64' { 'arm64' }
    'AMD64' { 'amd64' }
    default { Fail "Unsupported CPU architecture: $nativeArch" }
  }
  $name = "baize-mcp_${version}_windows_${arch}.zip"
  $asset = $metadata.assets | Where-Object name -eq $name | Select-Object -First 1
  $sums = $metadata.assets | Where-Object name -eq 'SHA256SUMS' | Select-Object -First 1
  if (-not $asset -or -not $sums) { Fail 'Baize MCP release has no matching Windows archive or checksum file.' }
  $temp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Path $temp | Out-Null
  try {
    $archive = Join-Path $temp $name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive
    $sumFile = Join-Path $temp 'SHA256SUMS'
    Invoke-WebRequest -Uri $sums.browser_download_url -OutFile $sumFile
    $expectedLine = Get-Content $sumFile | Where-Object {
      $parts = $_ -split '\s+'
      $parts.Count -ge 2 -and $parts[-1].TrimStart('*') -eq $name
    } | Select-Object -First 1
    $expected = if ($expectedLine) { ($expectedLine -split '\s+')[0] } else { '' }
    $actual = (Get-FileHash -Algorithm SHA256 -Path $archive).Hash
    if (-not $expected -or $actual -ne $expected.ToUpperInvariant()) { Fail 'Baize MCP archive checksum verification failed.' }
    $extract = Join-Path $temp 'extract'
    Expand-Archive -Path $archive -DestinationPath $extract
    $source = Get-ChildItem -Path $extract -Filter 'baize-mcp.exe' -File -Recurse | Select-Object -First 1
    $checksum = Get-ChildItem -Path $extract -Filter 'baize-mcp.sha256' -File -Recurse | Select-Object -First 1
    if (-not $source -or -not $checksum) { Fail 'The release archive does not contain the executable or integrity file.' }
    New-Item -ItemType Directory -Force -Path $mcpBinDir | Out-Null
    $stage = Join-Path $temp 'stage'
    $backup = Join-Path $temp 'backup'
    New-Item -ItemType Directory -Force -Path $stage, $backup | Out-Null
    $stageBinary = Join-Path $stage 'baize-mcp.exe'
    $stageChecksum = Join-Path $stage 'baize-mcp.sha256'
    Copy-Item $source.FullName $stageBinary -Force
    Copy-Item $checksum.FullName $stageChecksum -Force
    $installedVersion = (& $stageBinary version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { Fail 'Baize MCP runtime integrity verification failed.' }
    if ($installedVersion -ne $version) { Fail 'The installed Baize MCP version does not match the release version.' }
    $installedBinary = Join-Path $mcpBinDir 'baize-mcp.exe'
    $installedChecksum = Join-Path $mcpBinDir 'baize-mcp.sha256'
    $oldBinary = Join-Path $backup 'baize-mcp.exe'
    $oldChecksum = Join-Path $backup 'baize-mcp.sha256'
    try {
      if (Test-Path $installedBinary) { Move-Item $installedBinary $oldBinary -Force }
      if (Test-Path $installedChecksum) { Move-Item $installedChecksum $oldChecksum -Force }
      Move-Item $stageBinary $installedBinary -Force
      Move-Item $stageChecksum $installedChecksum -Force
    } catch {
      Remove-Item $installedBinary, $installedChecksum -Force -ErrorAction SilentlyContinue
      if (Test-Path $oldBinary) { Move-Item $oldBinary $installedBinary -Force }
      if (Test-Path $oldChecksum) { Move-Item $oldChecksum $installedChecksum -Force }
      Fail 'Baize MCP replacement failed; the previous version was restored.'
    }
    Say "已安装 Baize MCP ${version}：$mcpBinDir\baize-mcp.exe" "Installed Baize MCP ${version}: $mcpBinDir\baize-mcp.exe"
  } finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

$clientOrder = @('codex', 'claude', 'zcode', 'gemini', 'qwen', 'cursor', 'windsurf', 'vscode', 'cline', 'trae')
$script:TargetClients = @()

function Get-ClientConfigFile([string]$Name) {
  switch ($Name) {
    'zcode' { Join-Path $userHome '.zcode\cli\config.json' }
    'gemini' { Join-Path $userHome '.gemini\settings.json' }
    'qwen' { Join-Path $userHome '.qwen\settings.json' }
    'cursor' { Join-Path $userHome '.cursor\mcp.json' }
    'windsurf' { Join-Path $userHome '.codeium\windsurf\mcp_config.json' }
    'vscode' { Join-Path $env:APPDATA 'Code\User\mcp.json' }
    'cline' { Join-Path $env:APPDATA 'Code\User\globalStorage\saoudrizwan.claude-dev\settings\cline_mcp_settings.json' }
    'trae' { Join-Path $userHome '.trae\mcp.json' }
    default { '' }
  }
}

function Get-ClientConfigShape([string]$Name) {
  if ($Name -eq 'zcode') { 'zcode' } elseif ($Name -eq 'vscode') { 'vscode' } else { 'mcpServers' }
}

function Test-ClientDetected([string]$Name) {
  switch ($Name) {
    'codex' { (Test-Path (Join-Path $userHome '.codex')) -or (Get-Command codex -ErrorAction SilentlyContinue) }
    'claude' { (Test-Path (Join-Path $userHome '.claude')) -or (Get-Command claude -ErrorAction SilentlyContinue) }
    'zcode' { (Test-Path (Join-Path $userHome '.zcode')) -or (Get-Command zcode -ErrorAction SilentlyContinue) }
    'gemini' { (Test-Path (Join-Path $userHome '.gemini')) -or (Get-Command gemini -ErrorAction SilentlyContinue) }
    'qwen' { (Test-Path (Join-Path $userHome '.qwen')) -or (Get-Command qwen -ErrorAction SilentlyContinue) }
    'cursor' { Test-Path (Join-Path $userHome '.cursor') }
    'windsurf' { Test-Path (Join-Path $userHome '.codeium\windsurf') }
    'vscode' { Test-Path (Join-Path $env:APPDATA 'Code\User') }
    'cline' { Test-Path (Join-Path $env:APPDATA 'Code\User\globalStorage\saoudrizwan.claude-dev') }
    'trae' { Test-Path (Join-Path $userHome '.trae') }
    default { $false }
  }
}

function Resolve-TargetClients {
  if ($script:Client -eq 'manual') { return }
  if ($script:Client -ne 'auto') {
    if (Test-ClientDetected $script:Client) { $script:TargetClients = @($script:Client) }
    return
  }
  $detected = @()
  foreach ($name in $clientOrder) {
    if (Test-ClientDetected $name) { $detected += $name }
  }
  $script:TargetClients = $detected
}

function Upsert-McpFile([string]$ConfigFile, [string]$Shape, [string]$Binary) {
  if (Test-Path $ConfigFile) {
    try { $data = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable } catch { return 'parse-error' }
  } else {
    $data = @{}
  }
  $args = @('serve', '--profile', 'default')
  switch ($Shape) {
    'zcode' {
      if (-not $data.ContainsKey('mcp') -or $null -eq $data['mcp']) { $data['mcp'] = @{} }
      if (-not $data['mcp'].ContainsKey('servers') -or $null -eq $data['mcp']['servers']) { $data['mcp']['servers'] = @{} }
      $entry = [ordered]@{ type = 'stdio'; command = $Binary; args = $args }
      $servers = $data['mcp']['servers']
    }
    'vscode' {
      if (-not $data.ContainsKey('servers') -or $null -eq $data['servers']) { $data['servers'] = @{} }
      $entry = [ordered]@{ type = 'stdio'; command = $Binary; args = $args }
      $servers = $data['servers']
    }
    default {
      if (-not $data.ContainsKey('mcpServers') -or $null -eq $data['mcpServers']) { $data['mcpServers'] = @{} }
      $entry = [ordered]@{ command = $Binary; args = $args }
      $servers = $data['mcpServers']
    }
  }
  if ($servers.ContainsKey('baize')) {
    $current = $servers['baize']
    $same = ($current -is [hashtable]) -and
      ($current['command'] -eq $Binary) -and
      (($current['args'] -join ' ') -eq ($args -join ' ')) -and
      (($Shape -eq 'mcpServers') -or ($current['type'] -eq 'stdio'))
    if ($same) { return 'unchanged' }
  }
  $servers['baize'] = $entry
  try {
    $dir = Split-Path -Parent $ConfigFile
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $json = $data | ConvertTo-Json -Depth 16
    [IO.File]::WriteAllText($ConfigFile, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
  } catch {
    return 'write-error'
  }
  return 'updated'
}

function Register-CliClient([string]$Name, [string]$Binary) {
  $listOutput = (& $Name mcp list 2>$null | Out-String)
  $hasBaize = $listOutput -match '(^|\s)baize(\s|$|:)'
  $pointsToBinary = $listOutput -match [regex]::Escape($Binary)
  if ($hasBaize -and $pointsToBinary) { return $true }
  if ($hasBaize) { & $Name mcp remove baize 2>$null | Out-Null }
  if ($Name -eq 'codex') {
    & $Name mcp add baize -- $Binary serve --profile default 2>$null
    return ($LASTEXITCODE -eq 0)
  }
  & $Name mcp add -s user baize -- $Binary serve --profile default 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Resolve-ClientAndSkillDirs {
  Resolve-TargetClients
  $dirs = @()
  if ($SkillDir) {
    $dirs += $SkillDir
  } else {
    foreach ($name in $script:TargetClients) {
      $dir = switch ($name) {
        'codex' {
          $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $userHome '.codex' }
          Join-Path $codexHome 'skills\baize-ai'
        }
        'claude' { Join-Path $userHome '.claude\skills\baize-ai' }
        'zcode' { Join-Path $userHome '.zcode\skills\baize-ai' }
        default { '' }
      }
      if ($dir -and $dirs -notcontains $dir) { $dirs += $dir }
    }
    if (-not $dirs) { $dirs += (Join-Path $userHome '.baize\skills\baize-ai') }
  }
  return $dirs
}

function Install-Skill {
  $skillDirs = Resolve-ClientAndSkillDirs
  $skillSource = Join-Path $skillSourceDir 'SKILL.md'
  $metadataSource = Join-Path $skillSourceDir 'agents\openai.yaml'
  if (-not (Test-Path $skillSource) -or -not (Test-Path $metadataSource)) { Fail 'The current Baize copy does not contain the baize-ai Skill.' }
  foreach ($skillDir in $skillDirs) {
    New-Item -ItemType Directory -Force -Path (Join-Path $skillDir 'agents') | Out-Null
    Copy-Item $skillSource (Join-Path $skillDir 'SKILL.md') -Force
    Copy-Item $metadataSource (Join-Path $skillDir 'agents\openai.yaml') -Force
    Say "已安装 Baize Skill：$skillDir" "Installed Baize Skill: $skillDir"
  }
}

function Show-ManualConfig([string]$Binary) {
  Say '请将下面的 MCP 配置添加到 AI 客户端（不包含白泽地址或凭据）：' 'Add this MCP configuration to your AI client (it contains no Baize address or credential):'
  @{ mcpServers = @{ baize = @{ command = $Binary; args = @('serve', '--profile', 'default') } } } | ConvertTo-Json -Depth 4
}

function Register-Client {
  if ($SkipMcp) { return }
  $binary = Join-Path $mcpBinDir 'baize-mcp.exe'
  if (-not (Test-Path $binary)) { return }
  $registered = @()
  $failed = @()
  if ($Client -ne 'manual' -and $Client -ne 'auto' -and -not $script:TargetClients) {
    Say "未检测到 $Client，已跳过自动注册。" "$Client was not detected; automatic registration was skipped."
    Show-ManualConfig $binary
    return
  }
  foreach ($name in $script:TargetClients) {
    $ok = $false
    switch ($name) {
      { $_ -in @('codex', 'claude') } {
        if (Get-Command $name -ErrorAction SilentlyContinue) {
          $ok = Register-CliClient $name $binary
        }
      }
      { $_ -in @('gemini', 'qwen', 'zcode', 'cursor', 'windsurf', 'vscode', 'cline', 'trae') } {
        $configFile = Get-ClientConfigFile $name
        $result = Upsert-McpFile $configFile (Get-ClientConfigShape $name) $binary
        if ($result -eq 'updated') { Say "已将 Baize MCP 注册到 $name（$configFile）。" "Registered Baize MCP with $name ($configFile)."; $ok = $true }
        elseif ($result -eq 'unchanged') { Say "$name 中已存在一致的 Baize MCP 配置。" "Baize MCP is already configured in $name."; $ok = $true }
      }
    }
    if ($ok) { $registered += $name } else { $failed += $name }
  }
  if ($failed) {
    $failedNames = $failed -join ' '
    Say "未能自动注册到 $failedNames（客户端命令不可用、配置无法解析或写入失败）。下面给出手动配置；它不包含白泽地址或凭据。" "Automatic registration failed for $failedNames (client command unavailable, configuration unreadable, or write failed). Use the manual configuration below; it contains no Baize address or credential."
    Show-ManualConfig $binary
  } elseif (-not $registered -and $Client -ne 'manual') {
    Show-ManualConfig $binary
  }
}

Say '这不是白泽产品安装器，只安装 AI 接入组件（MCP 与 Skill）。' 'This is not the Baize product installer; it installs only the AI access components (MCP and Skill).'
Resolve-TargetClients
if (-not $SkipMcp) { Install-Mcp }
if (-not $SkipSkill) { Install-Skill }
Register-Client
if (-not $SkipMcp) {
  $mcpPath = Join-Path $mcpBinDir 'baize-mcp.exe'
  Say "下一步：在本机终端运行 $mcpPath login 登录你的白泽实例，再重新打开 AI 客户端。" "Next: run $mcpPath login in a local terminal for your Baize instance, then restart your AI client."
} else {
  Say '已跳过 MCP 安装；请确认现有 Baize MCP 已登录并已在 AI 客户端中启用。' 'MCP installation was skipped; make sure your existing Baize MCP is signed in and enabled in the AI client.'
}
