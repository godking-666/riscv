# build.ps1 --- boardtest (on-board bring-up self test) build driver
#
# ASCII only: Windows PowerShell 5.1 mis-parses BOM-less UTF-8 scripts.
#
# Usage (from the boardtest folder):
#   powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -RxWait 0     # skip the UART RX IRQ test
#   powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Install      # also write the images into the IPs
#
# Outputs in .\build\:
#   boardtest.elf / boardtest.map
#   inst_rom.dat   4096 hex words -> ipcore/inst_rom
#   data_ram.dat   4096 hex words -> ipcore/data_ram

param(
    [ValidateSet('boardtest')] [string]$Mode = 'boardtest',
    [string]$March = 'rv32i_zicsr',   # Zicsr needed for csrr/csrw in bsp/start.S
    [string]$Opt = '-Os',
    [int]$RxWait = 2,                 # seconds to wait for a UART RX interrupt (0 = skip test)
    [string]$Toolchain = '',
    [string]$ExtraCflags = '',
    [switch]$Clean,
    [switch]$Install,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$build = Join-Path $root 'build'

function Say($m) { if (-not $Quiet) { Write-Host $m } }

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

# ---------------------------------------------------------------- toolchain
function Find-Toolchain {
    param([string]$Hint)
    $names = @('riscv32-unknown-elf-gcc', 'riscv-none-elf-gcc',
               'riscv64-unknown-elf-gcc', 'riscv32-elf-gcc', 'riscv64-elf-gcc')

    if ($Hint -ne '') {
        if (Test-Path -LiteralPath $Hint -PathType Container) {
            foreach ($n in $names) {
                $p = Join-Path $Hint ("bin\$n.exe")
                if (Test-Path -LiteralPath $p) { return $p }
                $p = Join-Path $Hint "$n.exe"
                if (Test-Path -LiteralPath $p) { return $p }
            }
        } elseif (Test-Path -LiteralPath $Hint) { return $Hint }
        else {
            $c = Get-Command $Hint -ErrorAction SilentlyContinue
            if ($c) { return $c.Source }
        }
        throw "toolchain not found at '$Hint'"
    }

    if ($env:RISCV_GCC -and (Test-Path -LiteralPath $env:RISCV_GCC)) { return $env:RISCV_GCC }
    foreach ($n in $names) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    $globs = @(
        'D:\riscv\tools\*\bin\*-gcc.exe',
        'D:\riscv\tools\*\*\bin\*-gcc.exe',
        'C:\riscv*\*\bin\*-gcc.exe',
        "$env:USERPROFILE\xpack-*\*\bin\*-gcc.exe",
        "$env:USERPROFILE\.xpack\*\*\bin\*-gcc.exe"
    )
    foreach ($g in $globs) {
        $hit = Get-ChildItem -Path $g -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match 'riscv' } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

$gcc = Find-Toolchain -Hint $Toolchain
if (-not $gcc) {
    Write-Host "ERROR: no RISC-V GCC found. Install one, or pass -Toolchain <dir|exe>." -ForegroundColor Red
    exit 2
}
$bindir  = Split-Path -Parent $gcc
$size    = Join-Path $bindir ((Split-Path -Leaf $gcc) -replace 'gcc\.exe$', 'size.exe')

# ---------------------------------------------------------------- sources
$srcs = @(
    (Join-Path $root 'src\main.c'),
    (Join-Path $root 'src\console.c'),
    (Join-Path $root 'src\tests.c'),
    (Join-Path $root 'bsp\trap.c'),
    (Join-Path $root 'bsp\memops.c'),
    (Join-Path $root 'bsp\start.S')
)
foreach ($s in $srcs) {
    if (-not (Test-Path -LiteralPath $s)) { throw "missing source file: $s" }
}

$ld = Join-Path $root 'bsp\linker_onchip.ld'

if ($Clean -and (Test-Path -LiteralPath $build)) {
    Remove-Item -LiteralPath $build -Recurse -Force
    Say "cleaned $build"
}
New-Item -ItemType Directory -Force -Path $build | Out-Null

$elf = Join-Path $build 'boardtest.elf'
$map = Join-Path $build 'boardtest.map'
$rsp = Join-Path $build 'args.rsp'

# ---------------------------------------------------------------- flags
$optList = $Opt.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)

# Parenthesise every array element: PowerShell's comma operator binds tighter
# than '+', so without the parentheses the entries collapse into one string.
$inc = @(
    ('-I' + (Join-Path $root 'src')),
    ('-I' + (Join-Path $root 'bsp'))
)

$flags = @("-march=$March", '-mabi=ilp32', '-mcmodel=medlow') + $optList + @(
    '-ffreestanding', '-fno-builtin', '-fno-common', '-fno-strict-aliasing',
    '-ffunction-sections', '-fdata-sections',
    '-Wall', '-Wextra', '-Wno-unused-parameter',
    '-nostdlib', '-nostartfiles', '-nodefaultlibs'
) + $inc + @(
    "-DBT_RX_WAIT_SECONDS=$RxWait"
)
if ($ExtraCflags -ne '') {
    $flags += $ExtraCflags.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
}

$ldflags = @(
    "-Wl,-T,$ld",
    '-Wl,--gc-sections',
    # ROM and RAM are two physically separate memories sharing base 0x0, so ld's
    # generic LMA-overlap check always fires. linker_onchip.ld asserts the two
    # things that check would protect (text > ROM, data running into RAMTEST).
    '-Wl,--no-check-sections',
    "-Wl,-Map=$map",
    '-Wl,--print-memory-usage'
)

$lines  = @()
$lines += $flags
$lines += ($srcs | ForEach-Object { '"' + $_ + '"' })
$lines += '-o'
$lines += ('"' + $elf + '"')
$lines += $ldflags
$lines += '-lgcc'
# gcc treats '\' as an escape inside an @response file, so normalise to '/'
$lines = $lines | ForEach-Object { $_ -replace '\\', '/' }
$lines | Set-Content -LiteralPath $rsp -Encoding ascii

Say "== boardtest build =="
Say "   toolchain : $gcc"
Say "   version   : $((& $gcc -dumpversion) -join '')"
Say "   march     : $March   opt: $($optList -join ' ')"
Say "   rx wait   : $RxWait s   (0 = skip the UART RX interrupt test)"
Say ""

$rc = Invoke-Native $gcc @("@$rsp")
if ($rc -ne 0) { throw "compile/link failed (exit $rc)" }

Say ""
Say "== size =="
if (Test-Path -LiteralPath $size) {
    & $size -A $elf | Select-String -Pattern '\.text|\.rodata|\.data|\.bss|\.sdata|\.sbss|Total'
}

Say ""
Say "== images =="
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { throw "python not found; needed for tools/elf2dat.py" }

$rc = Invoke-Native $py @(
    (Join-Path $root 'tools\elf2dat.py'), $elf,
    '--rom-out', (Join-Path $build 'inst_rom.dat'),
    '--ram-out', (Join-Path $build 'data_ram.dat'))
if ($rc -ne 0) { Write-Host "image generation reported a size problem." -ForegroundColor Yellow }

if ($Install) {
    Say ""
    Say "== install into the PDS project =="
    $rc = Invoke-Native $py @(
        (Join-Path $root 'tools\install_to_ip.py'),
        '--name', 'boardtest',
        '--rom', (Join-Path $build 'inst_rom.dat'),
        '--ram', (Join-Path $build 'data_ram.dat'))
    if ($rc -ne 0) { throw "install_to_ip.py failed (exit $rc)" }
}

Say ""
Say "== done =="
Say "   next: PDS -> re-generate inst_rom and data_ram -> full build -> download"
Say "   LED : J16 clk alive, M17 ddr ready, K17 slow blink=RUN / steady=PASS / 4Hz=FAIL"
Say "   UART: 115200 8N1 on 40pin pin36(TX,AA20) pin35(RX,AA21) + GND"
