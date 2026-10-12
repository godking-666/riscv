# =============================================================================
# push_to_github.ps1 —— 把本工程推送到 GitHub
#
# 用法：
#   1. 先在 https://github.com/new 新建一个**空仓库**（不要勾 README/.gitignore/license）
#   2. 把下面的 $RepoUrl 改成你的仓库地址
#   3. 在本文件所在目录执行：  powershell -ExecutionPolicy Bypass -File push_to_github.ps1
#
# 认证说明（重要）：
#   GitHub 从 2021 年起**不再接受账号密码**做 git 操作。两种方式二选一：
#     A) HTTPS + Personal Access Token
#        在 https://github.com/settings/tokens 建一个 classic token（勾 repo 权限），
#        推送时用户名填 GitHub 用户名，**密码处粘贴 token**
#     B) SSH（推荐，一次配好长期用）
#        ssh-keygen -t ed25519 -C "你的邮箱"
#        把 ~/.ssh/id_ed25519.pub 内容贴到 https://github.com/settings/keys
#        然后把 $RepoUrl 改成 git@github.com:用户名/仓库名.git
# =============================================================================

$ErrorActionPreference = "Stop"

# ---- ★ 改这里 ★ ----
$RepoUrl = "https://github.com/<你的用户名>/<仓库名>.git"
# --------------------

$RepoDir = $PSScriptRoot
$Git = "C:\Program Files\Git\cmd\git.exe"
if (-not (Test-Path -LiteralPath $Git)) { $Git = "git" }   # 若已在 PATH 里

Set-Location -LiteralPath $RepoDir

Write-Host "=== 1) 检查仓库状态 ===" -ForegroundColor Cyan
& $Git status --short
$branch = & $Git rev-parse --abbrev-ref HEAD
Write-Host "  当前分支: $branch"
Write-Host "  提交数  : $(& $Git rev-list --count HEAD)"
Write-Host "  文件数  : $(& $Git ls-files | Measure-Object).Count"

Write-Host "`n=== 2) 配置远端 ===" -ForegroundColor Cyan
$existing = & $Git remote
if ($existing -contains "origin") {
    Write-Host "  已有 origin，更新为 $RepoUrl"
    & $Git remote set-url origin $RepoUrl
} else {
    Write-Host "  添加 origin -> $RepoUrl"
    & $Git remote add origin $RepoUrl
}
& $Git remote -v

Write-Host "`n=== 3) 分支改名 main ===" -ForegroundColor Cyan
if ($branch -ne "main") { & $Git branch -M main }

Write-Host "`n=== 4) 推送 ===" -ForegroundColor Cyan
Write-Host "  若提示输入密码，请粘贴 Personal Access Token（不是账号密码）"
& $Git push -u origin main

Write-Host "`n=== 完成 ===" -ForegroundColor Green
Write-Host "  仓库地址: $RepoUrl"
Write-Host "  验证方式: 浏览器打开仓库，应看到 交接说明与15天计划.md"
Write-Host ""
Write-Host "  团队克隆（注意：位流 9MB 会一起下来）:" -ForegroundColor Yellow
Write-Host "    git clone $RepoUrl"
Write-Host "  克隆后必须先重建工具链 junction，否则编译不了:" -ForegroundColor Yellow
Write-Host "    mklink /J <仓库>\xpack-riscv-none-elf-gcc-15.2.0-1 D:\riscv\tools\xpack-riscv-none-elf-gcc-15.2.0-1"
