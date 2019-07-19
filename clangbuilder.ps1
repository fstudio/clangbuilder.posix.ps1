#!/usr/bin/env pwsh
# build llvm on linux, mac use powershell
param(
    [ValidateSet("release", "stable", "master")]
    [String]$Branch = "master",
    [String]$Prefix,
    [String]$CC = "clang",
    [String]$CXX = "clang++"
)

Function Exec {
    param(
        [string]$FilePath,
        [string]$Argv,
        [string]$WD
    )
    $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
    $ProcessInfo.FileName = $FilePath
    Write-Host "$FilePath $Argv [$WD] "
    if ([String]::IsNullOrEmpty($WD)) {
        $ProcessInfo.WorkingDirectory = $PWD
    }
    else {
        $ProcessInfo.WorkingDirectory = $WD
    }
    $ProcessInfo.Arguments = $Argv
    $ProcessInfo.UseShellExecute = $false ## use createprocess not shellexecute
    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $ProcessInfo
    if ($Process.Start() -eq $false) {
        return -1
    }
    $Process.WaitForExit()
    return $Process.ExitCode
}


Function CloneFetchBranch {
    param(
        [string]$Branch,
        [string]$OutDir
    )
    $OutDir = Join-Path $PWD $OutDir
    $cloneargs = "clone https://github.com/llvm/llvm-project.git --branch `"$Branch`" --single-branch --depth=1 `"$OutDir`""
    if (Test-Path $OutDir) {
        $ex = Exec -FilePath "git" -Argv "checkout ." -WD "$OutDir"
        if ($ex -ne 0) {
            return $ex
        }
        $ex = Exec -FilePath "git" -Argv "pull" -WD "$OutDir"
        return $ex
    }
    return  Exec -FilePath "git" -Argv "$cloneargs" 
}


# https://github.com/llvm/llvm-project.git
$BWD = Join-Path -Path $PSScriptRoot "bwd"
if (!(Test-Path $BWD)) {
    New-Item -ItemType Directory -Path $BWD | Out-Null
}
Set-Location $BWD


$obj = Get-Content -Path "$PSScriptRoot/version.json" -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
if ($null -eq $obj -or ($null -eq $obj.Stable)) {
    Write-Host -ForegroundColor Red "version.json format is incorrect"
    exit 1
}
[char]$Esc = 0x1B
[string]$stable = $obj.Stable
[string]$release = $obj.Release
[string]$releaseurl = $obj.ReleaseUrl
[string]$MV = $obj.Mainline
[string]$releasedir = "llvmorg-$release"

if ([string]::IsNullOrEmpty($Prefix)) {
    if ($Branch -eq "master") {
        $Prefix = "/opt/llvm-" + $MV
    }
    elseif ($Branch -eq "stable") {
        $Prefix = "/opt/llvm-stable"
    }
    else {
        $Prefix = "/opt/llvm"
    }
}

Write-Host "LLVM master version $Esc[1;32m$MV$Esc[0m. stable branch is $Esc[1;32m$stable$Esc[0m. latest release is: $Esc[1;32m$release$Esc[0m
Your select to build '$Esc[1;32m$Branch$Esc[0m' mode
The prefix you chose is: $Esc[1;33m$Prefix$Esc[0m"

$sourcedir = "mainline"
if ($Branch -eq "stable") {
    $sourcedir = $stable -replace "(\\|\/)", "_"
    $ex = CloneFetchBranch -Branch $stable -OutDir $sourcedir
    if ($ex -ne 0) {
        exit $ex
    }
}
elseif ($Branch -eq "release") {
    $sourcedir = $Branch
    $curlcliv = Get-COmmand -CommandType Application -ErrorAction SilentlyContinue "curl"
    if ($null -eq $curlcliv) {
        Write-Host -ForegroundColor "Please install curl to allow download llvm"
        exit 1
    }
    $curlcli = $curlcliv[0].Source
    $outfile = "$releasedir.tar.gz"
    Write-Host "Download file: $outfile"
    $ex = Exec -FilePath "$curlcli" -Argv "--progress-bar -fS --connect-timeout 15 --retry 3 -o $outfile -L --proto-redir =https $releaseurl" -WD $PWD
    if ($ex -ne 0) {
        exit 1
    }
    tar -xvf "$outfile"
    $sourcedir = $releasedir
}
else {
    $ex = CloneFetchBranch -Branch $stable -OutDir $sourcedir
    if ($ex -ne 0) {
        exit $ex
    }
}

Write-Host "The source directory is expanded to $Esc[1;34m$sourcedir$Esc[0m"
$OutDir = Join-Path $PWD "$sourcedir.out"
$SrcDir = Join-Path $PWD "$sourcedir"
New-Item -ItemType Directory "$sourcedir.out" -ErrorAction SilentlyContinue | Out-Null
$AllowProjects = "clang;clang-tools-extra;compiler-rt;libcxx;libcxxabi;libunwind;lld;lldb"
$AllowTargets = "X86;AArch64;ARM;BPF"

$CMakeArgv = @(
    "-GNinja",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DLLVM_ENABLE_ASSERTIONS=OFF",
    "-DLLVM_TARGETS_TO_BUILD=`"$AllowTargets`"",
    "-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=`"RISCV;WebAssembly`"",
    "-DLLVM_ENABLE_PROJECTS=`"$AllowProjects`"",
    "-DCMAKE_C_COMPILER=`"$CC`"",
    "-DCMAKE_CXX_COMPILER=`"$CXX`"",
    "-DCLANG_DEFAULT_LINKER=lld",
    "-DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON",
    "-DLLVM_HOST_TRIPLE=`"x86_64-fbi-linux-gnu`"",
    "-DCMAKE_INSTALL_PREFIX=`"$Prefix`"",
    "-DCLANG_REPOSITORY_STRING=`"clangbuilder.io`"",
    "`"$SrcDir/llvm`""
    # enable argv table
)

[System.Text.StringBuilder]$CMakeArgsBuilder = New-Object -TypeName System.Text.StringBuilder
foreach ($s in $CMakeArgv) {
    if ($CMakeArgsBuilder.Length -ne 0) {
        $CMakeArgsBuilder.Append(" ")
    }
    $CMakeArgsBuilder.Append($s)
}

$CMakeArgs = $CMakeArgsBuilder.ToString()

Write-Host -ForegroundColor Gray "cmake $CMakeArgs"

$ex = Exec -FilePath "cmake" -Argv "$CMakeArgs" -WD "$OutDir"
if ($ex -ne 0) {
    exit $ex
}
$ex = Exec -FilePath "ninja" -Argv "all" -WD "$OutDir"
if ($ex -ne 0) {
    exit $ex
}

Write-Host -ForegroundColor Green "build success, you can run ninja install to install llvm"