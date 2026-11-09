$ErrorActionPreference = "Stop"

function Convert-SecureStringToPlainText([Security.SecureString]$Value) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

$keytoolCommand = Get-Command keytool.exe -ErrorAction SilentlyContinue
if (-not $keytoolCommand) {
    $keytoolCommand = Get-Command keytool -ErrorAction SilentlyContinue
}
if (-not $keytoolCommand -and $env:JAVA_HOME) {
    $candidate = Join-Path $env:JAVA_HOME "bin\keytool.exe"
    if (Test-Path $candidate) {
        $keytoolCommand = Get-Item $candidate
    }
}
if (-not $keytoolCommand) {
    throw "找不到 keytool。请先安装 JDK 21，或使用 Android Studio 自带的 JBR，并将其 bin 目录加入 PATH。"
}
$keytool = $keytoolCommand.Source
if (-not $keytool) { $keytool = $keytoolCommand.Definition }

$directory = Join-Path $env:USERPROFILE "Documents\MoodiarySigning"
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$keystore = Join-Path $directory "moodiary-v3-safe-key.jks"
if (Test-Path $keystore) {
    throw "签名文件已存在，拒绝覆盖：$keystore。未来版本必须继续使用同一密钥。"
}

$securePassword = Read-Host "设置新的签名密码（至少 20 位，仅字母和数字）" -AsSecureString
$password = Convert-SecureStringToPlainText $securePassword
if ($password.Length -lt 20 -or $password -notmatch '^[A-Za-z0-9]+$') {
    throw "密码必须至少 20 位，并且只能使用英文字母和数字。"
}

Write-Host "正在创建新的、独立于旧版的 Android 签名密钥……"
$keyArgs = @(
    "-genkeypair", "-v",
    "-keystore", $keystore,
    "-storetype", "JKS",
    "-alias", "key0",
    "-keyalg", "RSA",
    "-keysize", "4096",
    "-validity", "10000",
    "-dname", "CN=Moodiary V3 Safe, OU=App Signing, O=Private, C=CN",
    "-storepass", $password,
    "-keypass", $password,
    "-noprompt"
)
& $keytool @keyArgs
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $keystore)) {
    throw "签名密钥生成失败。"
}

$listing = & $keytool -list -v -keystore $keystore -storepass $password -alias key0
if ($LASTEXITCODE -ne 0) { throw "无法读取新签名证书。" }
$fingerprintLine = $listing | Where-Object { $_ -match 'SHA256:' } | Select-Object -First 1
if (-not $fingerprintLine) { throw "无法提取证书 SHA-256 指纹。" }
$fingerprint = (($fingerprintLine -replace '^.*SHA256:\s*', '') -replace ':', '').Trim().ToLowerInvariant()
if ($fingerprint -notmatch '^[0-9a-f]{64}$') { throw "证书 SHA-256 指纹格式异常。" }

$base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($keystore))
Set-Clipboard -Value $base64

Write-Host ""
Write-Host "签名密钥已创建。请勿删除或重新生成。"
Write-Host "JKS 文件：$keystore"
Write-Host "Base64 已复制到剪贴板。"
Write-Host "证书 SHA-256：$fingerprint"
Write-Host ""
Write-Host "在 GitHub 仓库 Settings → Secrets and variables → Actions 中添加："
Write-Host "MOODIARY_SAFE_KEYSTORE_BASE64 = 剪贴板中的 Base64"
Write-Host "MOODIARY_SAFE_STORE_PASSWORD = 你刚设置的密码"
Write-Host "MOODIARY_SAFE_KEY_PASSWORD = 同一个密码"
Write-Host "MOODIARY_SAFE_CERT_SHA256 = 上面打印的 64 位指纹"
Write-Host ""
Write-Host "请将 JKS 文件另存两份离线备份。不要把 JKS 或密码提交到 Git。"
