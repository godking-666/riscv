# build.ps1 --- CoreMark build driver for this RISC-V SoC project
#
# ASCII only on purpose: Windows PowerShell 5.1 mis-parses BOM-less UTF-8 scripts.
#
# Usage (from the coremark folder):
#   powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Iterations 100
#   powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Opt -Os
#   powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Mode ddr
#   powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Install
#   powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Clean
#
# Outputs (in .\build\):
#   coremark.elf / coremark.map
#   inst_rom.dat    4096 hex words, for ipcore/inst_rom   (onchip mode)
#   data_ram.dat    4096 hex words, for ipcore/data_ram   (onchip mode)
#   coremark.bin    flat binary                            (ddr mode)

param(
    [ValidateSet('onchip', 'ddr')] [string]$Mode = 'onchip',
    [int]$Iterations = 0,
    [string]$Opt = '-O2',
    # Zicsr is required for csrr/csrw in bsp/start.S. This CPU does implement the
    # Zicsr instructions, so rv32i_zicsr describes it accurately. After adding the
    # M extension use -March rv32im_zicsr for the A/B comparison.
    [string]$March = 'rv32i_zicsr',
    [string]$Toolchain = '',
    [string]$ExtraCflags = '',
    [switch]$Clean,
    [switch]$Install,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$proj = Split-Path -Parent $root
$build = Join-Path $root 'build'

function Say($m) { if (-not $Quiet) { Write-Host $m } }

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
        } elseif (Test-Path -LiteralPath $Hint) {
            return $Hint
        } else {
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
        "$env:USERPROFILE\.xpack\*\*\bin\*-gcc.exe",
        'C:\Program Files\xpack-*\*\bin\*-gcc.exe',
        "$env:APPDATA\xPacks\*\*\bin\*-gcc.exe"
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
    Write-Host "ERROR: no RISC-V GCC found." -ForegroundColor Red
    Write-Host "Install one (competition asks for riscv32-unknown-elf-gcc), or pass -Toolchain <dir|exe>."
    Write-Host "Portable option: download xpack riscv-none-elf-gcc win32-x64 zip, extract to D:\riscv\tools\"
    exit 2
}
$bindir = Split-Path -Parent $gcc
$size   = Join-Path $bindir ((Split-Path -Leaf $gcc) -replace 'gcc\.exe$', 'size.exe')
$objdump = Join-Path $bindir ((Split-Path -Leaf $gcc) -replace 'gcc\.exe$', 'objdump.exe')

# ---------------------------------------------------------------- sources
$official = @(
    'core_main.c', 'core_list_join.c', 'core_matrix.c',
    'core_state.c', 'core_util.c'
) | ForEach-Object { Join-Path $root "official\$_" }

$port = @('core_portme.c', 'ee_printf.c') | ForEach-Object { Join-Path $root "port\$_" }
$bsp  = @('start.S', 'memops.c')          | ForEach-Object { Join-Path $root "bsp\$_" }

$srcs = @($official) + @($port) + @($bsp)
foreach ($s in $srcs) {
    if (-not (Test-Path -LiteralPath $s)) { throw "missing source file: $s" }
}

$ld = Join-Path $root $(if ($Mode -eq 'ddr') { 'bsp\linker_ddr.ld' } else { 'bsp\linker_onchip.ld' })

# ---------------------------------------------------------------- dirs
if ($Clean -and (Test-Path -LiteralPath $build)) {
    Remove-Item -LiteralPath $build -Recurse -Force
    Say "cleaned $build"
}
New-Item -ItemType Directory -Force -Path $build | Out-Null

$elf = Join-Path $build 'coremark.elf'
$map = Join-Path $build 'coremark.map'
$rsp = Join-Path $build 'args.rsp'

# ---------------------------------------------------------------- flags
$optList = $Opt.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
$std = @(
    "-march=$March", '-mabi=ilp32', '-mcmodel=medlow'
) + $optList + @(
    '-ffreestanding', '-fno-builtin', '-fno-common', '-fno-strict-aliasing',
    '-ffunction-sections', '-fdata-sections',
    '-Wall', '-Wextra', '-Wno-unused-parameter',
    # false positive inside the unmodified official core_list_join.c
    '-Wno-maybe-uninitialized',
    '-nostdlib', '-nostartfiles', '-nodefaultlibs'
)

# NOTE: every element must be parenthesised. Without the parentheses PowerShell's
# comma operator binds tighter than '+', so the three entries would collapse into
# one space-joined string and gcc would never see an -I option.
$inc = @(
    ('-I' + (Join-Path $root 'official')),
    ('-I' + (Join-Path $root 'port')),
    ('-I' + (Join-Path $root 'bsp'))
)

$defs = @(
    "-DITERATIONS=$Iterations",
    '-DPERFORMANCE_RUN=1',
    '-DTOTAL_DATA_SIZE=2000',
    '-DCM_CONSOLE=1'
)

# A -D macro whose value contains spaces cannot survive the @response-file
# round trip: gcc strips the quotes while reading the file and then re-splits the
# argument on whitespace when it invokes cc1, so every word becomes its own
# definition. Emit the flags string as a tiny generated header and -include it.
$flagsStr = (($std + $inc + $defs) -join ' ') -replace '\\', '/'
$flagsHeader = Join-Path $build 'cm_build_flags.h'
@(
    '/* auto-generated by build.ps1 -- do not edit */',
    '#ifndef CM_BUILD_FLAGS_H',
    '#define CM_BUILD_FLAGS_H',
    ('#define FLAGS_STR "' + $flagsStr + '"'),
    '#endif'
) | Set-Content -LiteralPath $flagsHeader -Encoding ascii

$inc += ('-I' + $build)
$std += '-include', 'cm_build_flags.h'

# Keep linker options conservative: every one of these has been available for many
# binutils releases, so the competition's own riscv32-unknown-elf-gcc will accept them.
# (RWX-segment warnings are harmless and intentionally left visible.)
#
# --no-check-sections: on this board the 16 KiB instruction ROM and the 16 KiB data
# RAM are two physically separate memories that legitimately share base address 0x0,
# so ld's generic "section LMA overlaps" check always fires. The two things that
# check would have protected are asserted explicitly inside linker_onchip.ld
# (text > ROM, and data running into the stack region), so disabling it is safe.
$ldflags = @(
    "-Wl,-T,$ld",
    '-Wl,--gc-sections',
    '-Wl,--no-check-sections',
    "-Wl,-Map=$map",
    '-Wl,--print-memory-usage'
)

if ($ExtraCflags -ne '') {
    $defs += $ExtraCflags.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
}

# response file avoids every PowerShell native-argument quoting pitfall
$lines = @()
$lines += $std
$lines += $inc
$lines += $defs
$lines += ($srcs | ForEach-Object { '"' + $_ + '"' })
$lines += '-o'
$lines += ('"' + $elf + '"')
$lines += $ldflags
$lines += '-lgcc'

# GCC treats '\' as an escape character inside an @response file, so a Windows
# path like C:\Users\... would silently become C:Users... . Forward slashes are
# accepted by gcc/ld/as on Windows, so normalise every line.
$lines = $lines | ForEach-Object { $_ -replace '\\', '/' }
$lines | Set-Content -LiteralPath $rsp -Encoding ascii

Say "== CoreMark build =="
Say "   toolchain : $gcc"
Say ("   version   : " + ((& $gcc -dumpversion) -join ''))
Say "   mode      : $Mode   (linker $(Split-Path -Leaf $ld))"
Say "   opt       : $($optList -join ' ')"
Say "   iterations: $Iterations  (0 = CoreMark auto-scales to >= 10 s)"
Say "   elf       : $elf"
Say ""

# ---------------------------------------------------------------- build
# Run a native command, streaming both stdout and stderr, and return its exit code.
# Needed because with $ErrorActionPreference='Stop' PowerShell turns any stderr
# line (e.g. a harmless gcc warning) into a terminating NativeCommandError.
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

$rc = Invoke-Native $gcc @("@$rsp")
if ($rc -ne 0) { throw "compile/link failed (exit $rc)" }

Say ""
Say "== size =="
if (Test-Path -LiteralPath $size) {
    & $size -A $elf | Select-String -Pattern '\.text|\.rodata|\.data|\.bss|\.sdata|\.sbss|Total'
} else {
    Say "   (size.exe not found next to gcc; see the memory usage block above)"
}

Say ""
Say "== images =="
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { throw "python not found; needed for tools/elf2dat.py" }
$elf2dat = Join-Path $root 'tools\elf2dat.py'

if ($Mode -eq 'onchip') {
    $rc = Invoke-Native $py @($elf2dat, $elf,
        '--rom-out', (Join-Path $build 'inst_rom.dat'),
        '--ram-out', (Join-Path $build 'data_ram.dat'))
} else {
    $rc = Invoke-Native $py @($elf2dat, $elf, '--flat', (Join-Path $build 'coremark.bin'))
}
if ($rc -ne 0) {
    Write-Host ""
    Write-Host "Image generation reported a size problem." -ForegroundColor Yellow
    Write-Host "Try: -Opt -Os   |   -DCM_CONSOLE=0   |   expand the ROM/RAM IP (see README.md)"
}

# ---------------------------------------------------------------- install
if ($Install) {
    Say ""
    Say "== install into the PDS project =="
    $inst = Join-Path $root 'tools\install_to_ip.py'
    if ($Mode -eq 'onchip') {
        $rc = Invoke-Native $py @($inst,
            '--rom', (Join-Path $build 'inst_rom.dat'),
            '--ram', (Join-Path $build 'data_ram.dat'))
        if ($rc -ne 0) { throw "install_to_ip.py failed (exit $rc)" }
    } else {
        Say "   ddr mode: nothing to install into the ROM/RAM IPs; load coremark.bin by your own loader."
    }
}

Say ""
Say "== done =="
Say "   next: open RISCV.pds -> regenerate inst_rom / data_ram IP -> full build -> download"
Say "   serial: 115200 8N1, expect the CoreMark report then 'CoreMark 1.0 : <score> / ...'"
