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
$repoRoot = Split-Path -Parent $PSScriptRoot

function Fail([string]$Message) { throw $Message }

if ($Help) {
  Write-Host 'Baize AI access upgrader (updates MCP and Skill only).'
  Write-Host 'It fast-forwards the public baize entry, then runs install-ai-access.ps1.'
  Write-Host 'It does not install or upgrade the Baize server, console, or Agent.'
  Write-Host 'Example: .\upgrade-ai-access.ps1 -Lang en -Client codex'
  exit 0
}

if (-not (Test-Path (Join-Path $repoRoot '.git'))) {
  Fail 'Run this script from a baize directory cloned with Git so the public AI instructions and Skill can be updated together.'
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Fail 'Git is required to update the public AI access entry.'
}

$status = (& git -C $repoRoot status --porcelain --untracked-files=all | Out-String).Trim()
if ($status) {
  Fail 'The baize directory has local changes. Commit or stash them before upgrading; this script never overwrites local content.'
}

& git -C $repoRoot pull --ff-only
if ($LASTEXITCODE -ne 0) {
  Fail 'The public entry could not be updated. Check the network, remote branch, and local Git state, then retry.'
}

$installer = Join-Path $repoRoot 'scripts/install-ai-access.ps1'
$installerArgs = @('-Lang', $Lang, '-Client', $Client, '-McpVersion', $McpVersion)
if ($SkillDir) { $installerArgs += @('-SkillDir', $SkillDir) }
if ($SkipMcp) { $installerArgs += '-SkipMcp' }
if ($SkipSkill) { $installerArgs += '-SkipSkill' }
& $installer @installerArgs
exit $LASTEXITCODE
