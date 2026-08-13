param(
  [ValidateSet('zh', 'en')][string]$Lang = 'zh',
  [ValidateSet('auto', 'codex', 'claude', 'manual')][string]$Client = 'auto',
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
  Write-Host 'Usage: .\install-ai-access.ps1 [-Lang zh|en] [-Client auto|codex|claude|manual] [-SkillDir path] [-McpVersion latest|x.y.z] [-SkipMcp] [-SkipSkill]'
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

function Resolve-Client {
  if ($script:Client -ne 'auto') { return }
  $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $userHome '.codex' }
  if ((Test-Path $codexHome) -or (Get-Command codex -ErrorAction SilentlyContinue)) { $script:Client = 'codex' }
  elseif ((Test-Path (Join-Path $userHome '.claude')) -or (Get-Command claude -ErrorAction SilentlyContinue)) { $script:Client = 'claude' }
  else { $script:Client = 'manual' }
}

function Resolve-ClientAndSkillDir {
  Resolve-Client
  if (-not $script:SkillDir) {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $userHome '.codex' }
    if ($Client -eq 'codex') { $script:SkillDir = Join-Path $codexHome 'skills\baize-ai' }
    elseif ($Client -eq 'claude') { $script:SkillDir = Join-Path $userHome '.claude\skills\baize-ai' }
    else { $script:SkillDir = Join-Path $userHome '.baize\skills\baize-ai' }
  }
}

function Install-Skill {
  Resolve-ClientAndSkillDir
  $skillSource = Join-Path $skillSourceDir 'SKILL.md'
  $metadataSource = Join-Path $skillSourceDir 'agents\openai.yaml'
  if (-not (Test-Path $skillSource) -or -not (Test-Path $metadataSource)) { Fail 'The current Baize copy does not contain the baize-ai Skill.' }
  New-Item -ItemType Directory -Force -Path (Join-Path $SkillDir 'agents') | Out-Null
  Copy-Item $skillSource (Join-Path $SkillDir 'SKILL.md') -Force
  Copy-Item $metadataSource (Join-Path $SkillDir 'agents\openai.yaml') -Force
  Say "已安装 Baize Skill：$SkillDir" "Installed Baize Skill: $SkillDir"
}

function Register-Client {
  if ($SkipMcp) { return }
  Resolve-Client
  $binary = Join-Path $mcpBinDir 'baize-mcp.exe'
  if (-not (Test-Path $binary)) { return }
  $registered = $false
  if ($Client -eq 'codex' -and (Get-Command codex -ErrorAction SilentlyContinue)) {
    $existing = & codex mcp list 2>$null | Out-String
    $configured = & codex mcp get baize 2>$null | Out-String
    if ($existing -match '(^|\s)baize(\s|$)' -and $configured -match [regex]::Escape("command: $binary")) { $registered = $true }
    elseif ($existing -match '(^|\s)baize(\s|$)') { & codex mcp remove baize 2>$null; & codex mcp add baize -- $binary serve --profile default; $registered = ($LASTEXITCODE -eq 0) }
    else { & codex mcp add baize -- $binary serve --profile default; $registered = ($LASTEXITCODE -eq 0) }
  } elseif ($Client -eq 'claude' -and (Get-Command claude -ErrorAction SilentlyContinue)) {
    $existing = & claude mcp list 2>$null | Out-String
    if ($existing -match '(^|\s)baize(\s|$)' -and $existing -match [regex]::Escape($binary)) { $registered = $true }
    elseif ($existing -match '(^|\s)baize(\s|$)') { & claude mcp remove baize 2>$null; & claude mcp add baize -- $binary serve --profile default; $registered = ($LASTEXITCODE -eq 0) }
    else { & claude mcp add baize -- $binary serve --profile default; $registered = ($LASTEXITCODE -eq 0) }
  }
  if ($registered) {
    Say "已尝试将 Baize MCP 注册到 $Client。" "Baize MCP registration was added or already exists in $Client."
  } else {
    if ($Client -ne 'manual') {
      Say "未能自动注册到 $Client（客户端命令不可用或注册失败）。下面给出手动配置；它不包含白泽地址或凭据。" "Automatic registration with $Client was unavailable or failed. Use the manual configuration below; it contains no Baize address or credential."
    }
    Say '请将下面的 MCP 配置添加到 AI 客户端（不包含白泽地址或凭据）：' 'Add this MCP configuration to your AI client (it contains no Baize address or credential):'
    @{ mcpServers = @{ baize = @{ command = $binary; args = @('serve', '--profile', 'default') } } } | ConvertTo-Json -Depth 4
  }
}

Say '这不是白泽产品安装器，只安装 AI 接入组件（MCP 与 Skill）。' 'This is not the Baize product installer; it installs only the AI access components (MCP and Skill).'
if (-not $SkipMcp) { Install-Mcp }
if (-not $SkipSkill) { Install-Skill }
Register-Client
if (-not $SkipMcp) {
  $mcpPath = Join-Path $mcpBinDir 'baize-mcp.exe'
  Say "下一步：在本机终端运行 $mcpPath login 登录你的白泽实例，再重新打开 AI 客户端。" "Next: run $mcpPath login in a local terminal for your Baize instance, then restart your AI client."
} else {
  Say '已跳过 MCP 安装；请确认现有 Baize MCP 已登录并已在 AI 客户端中启用。' 'MCP installation was skipped; make sure your existing Baize MCP is signed in and enabled in the AI client.'
}
