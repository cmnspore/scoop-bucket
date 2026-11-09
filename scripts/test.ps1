param(
    [ValidateSet("Static", "Install", "All")]
    [string]$Mode = "All",
    [string]$Manifest = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$AllowedKeys = @("architecture", "bin", "description", "homepage", "license", "version")
$ForbiddenKeys = @("installer", "post_install", "pre_install", "script", "uninstaller")

# The bucket is published under the organization its release downloads come from.
function Get-Organization {
    if (@(Get-ChildItem -LiteralPath (Join-Path $Root "bucket") -Filter "*.json" -File).Count -eq 0) {
        throw "Bucket contains no manifests"
    }
    $Organizations = @(Get-ChildItem -LiteralPath (Join-Path $Root "bucket") -Filter "*.json" -File |
        ForEach-Object { ((Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).architecture."64bit".url -replace '^https://github\.com/([^/]+)/.*$', '$1') } |
        Sort-Object -Unique)
    if ($Organizations.Count -ne 1 -or $Organizations[0] -cnotmatch "^[A-Za-z0-9._-]+$") {
        throw "manifests must name exactly one GitHub organization"
    }
    return $Organizations[0]
}
$Organization = Get-Organization

function Get-Manifests {
    if ($Manifest) {
        $Path = Join-Path $Root $Manifest
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Manifest not found: $Manifest"
        }
        return @(Get-Item -LiteralPath $Path)
    }
    $Files = @(Get-ChildItem -LiteralPath (Join-Path $Root "bucket") -Filter "*.json" -File | Sort-Object Name)
    if ($Files.Count -eq 0) {
        throw "Bucket contains no manifests"
    }
    return $Files
}

function Test-Static {
    $Manifests = @(Get-Manifests)
    $Readme = Get-Content -LiteralPath (Join-Path $Root "README.md") -Raw
    if ($Readme.Contains("<bin>")) {
        throw "README contains a PowerShell-significant binary placeholder"
    }
    foreach ($File in $Manifests) {
        $Name = $File.BaseName
        $Document = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json
        $Keys = @($Document.PSObject.Properties.Name | Sort-Object)
        if (Compare-Object $AllowedKeys $Keys) {
            throw "$($File.Name): top-level fields differ from the declarative allowlist"
        }
        foreach ($Key in $ForbiddenKeys) {
            if ($Document.PSObject.Properties.Name -contains $Key) {
                throw "$($File.Name): forbidden script field $Key"
            }
        }
        $Architectures = @($Document.architecture.PSObject.Properties.Name)
        if ($Architectures.Count -ne 1 -or $Architectures[0] -ne "64bit") {
            throw "$($File.Name): only an explicit 64bit package is supported"
        }
        $Asset = $Document.architecture."64bit"
        if ($Asset.url -cnotmatch "^https://github\.com/$([regex]::Escape($Organization))/cmn-[a-z0-9-]+/releases/download/v$([regex]::Escape($Document.version))/$Name-v$([regex]::Escape($Document.version))-x86_64-pc-windows-msvc\.zip$") {
            throw "$($File.Name): URL is not the versioned x64 Windows asset"
        }
        if ($Asset.hash -cnotmatch "^[0-9a-f]{64}$") {
            throw "$($File.Name): hash is not 64 lowercase hex characters"
        }
        $Binaries = @($Document.bin)
        if ($null -eq $Document.bin -or $Binaries.Count -eq 0) {
            throw "$($File.Name): bin must declare at least one binary"
        }
        if (@($Binaries | Sort-Object -Unique).Count -ne $Binaries.Count) {
            throw "$($File.Name): binary shims must be unique (case-insensitive)"
        }
        foreach ($Binary in $Binaries) {
            if ($Binary -cnotmatch "^[a-z][a-z0-9-]*\.exe$") {
                throw "$($File.Name): invalid binary shim $Binary"
            }
        }
        if (-not $Readme.Contains("scoop install $Organization/$Name")) {
            throw "README lacks the concrete install command for $Name"
        }
    }
}

function Test-InstalledCommand([string]$Name, [string]$TempRoot) {
    # Every command documents itself offline; a binary that starts and prints its
    # reference is a binary that loaded.
    $Output = @(& $Name --docs)
    if ($LASTEXITCODE -ne 0 -or ($Output -join "`n") -notmatch "CLI reference") {
        throw "$Name docs smoke failed"
    }
}

function Test-Install {
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        throw "Scoop is required for Install mode"
    }
    $Manifests = @(Get-Manifests)
    $Buckets = @(scoop bucket list)
    $BucketListExit = $LASTEXITCODE
    if ($BucketListExit -ne 0 -and $BucketListExit -ne 2) {
        throw "Scoop bucket list failed with exit $BucketListExit"
    }
    if ($Buckets | Where-Object { $_.Name -eq $Organization }) {
        throw "Refusing to alter an already-registered bucket: $Organization"
    }

    $TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cmn-scoop-test-" + [Guid]::NewGuid())
    $TempRootCreated = $false
    $BucketAdded = $false
    $PrimaryFailure = $null
    $CleanupFailures = @()
    try {
        New-Item -ItemType Directory -Path $TempRoot | Out-Null
        $TempRootCreated = $true
        # Scoop validates Git repository paths using forward slashes, including
        # a Windows checkout path. Registration belongs to this run only after
        # add succeeds; an existing or failed registration is never removed.
        $LocalCheckout = $Root.Replace('\', '/')
        scoop bucket add $Organization $LocalCheckout | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Local bucket registration failed with exit $LASTEXITCODE"
        }
        $BucketAdded = $true

        foreach ($File in $Manifests) {
            $Name = $File.BaseName
            $Document = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json
            $Commands = @($Document.bin | ForEach-Object {
                [System.IO.Path]::GetFileNameWithoutExtension($_)
            })
            scoop prefix $Name 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                throw "Refusing to alter an already-installed package: $Name"
            }

            $InstallAttempted = $false
            $PackageFailure = $null
            $PackageCleanupFailures = @()
            try {
                $InstallAttempted = $true
                scoop install "$Organization/$Name" | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "$Name install failed with exit $LASTEXITCODE"
                }
                $VersionPattern = "(?<![0-9A-Za-z.+-])" + [regex]::Escape($Document.version) + "(?![0-9A-Za-z.+-])"
                foreach ($Command in $Commands) {
                    $VersionOutput = @(& $Command --version)
                    if ($LASTEXITCODE -ne 0) {
                        throw "$Command --version failed with exit $LASTEXITCODE"
                    }
                    if (($VersionOutput -join "`n") -notmatch $VersionPattern) {
                        throw "$Command --version does not match manifest version $($Document.version)"
                    }
                }
                Test-InstalledCommand $Name $TempRoot
            }
            catch {
                $PackageFailure = $_
            }
            finally {
                if ($InstallAttempted) {
                    try {
                        scoop uninstall $Name | Out-Null
                        if ($LASTEXITCODE -ne 0) {
                            throw "$Name cleanup failed with exit $LASTEXITCODE"
                        }
                    }
                    catch {
                        $PackageCleanupFailures += $_
                    }
                    foreach ($Command in $Commands) {
                        try {
                            if (Get-Command $Command -ErrorAction SilentlyContinue) {
                                throw "$Name uninstall left the $Command shim on PATH"
                            }
                        }
                        catch {
                            $PackageCleanupFailures += $_
                        }
                    }
                }
                foreach ($Failure in $PackageCleanupFailures) {
                    Write-Error -ErrorRecord $Failure -ErrorAction Continue
                }
            }
            if ($PackageFailure) {
                throw $PackageFailure
            }
            if ($PackageCleanupFailures.Count -gt 0) {
                throw $PackageCleanupFailures[0]
            }
        }
    }
    catch {
        $PrimaryFailure = $_
    }
    finally {
        if ($BucketAdded) {
            try {
                scoop bucket rm $Organization | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Local bucket cleanup failed with exit $LASTEXITCODE"
                }
            }
            catch {
                $CleanupFailures += $_
            }
        }
        try {
            if ($TempRootCreated -and (Test-Path -LiteralPath $TempRoot)) {
                Remove-Item -LiteralPath $TempRoot -Recurse -Force
            }
        }
        catch {
            $CleanupFailures += $_
        }
        foreach ($Failure in $CleanupFailures) {
            Write-Error -ErrorRecord $Failure -ErrorAction Continue
        }
    }
    if ($PrimaryFailure) {
        throw $PrimaryFailure
    }
    if ($CleanupFailures.Count -gt 0) {
        throw $CleanupFailures[0]
    }
}

switch ($Mode) {
    "Static" { Test-Static }
    "Install" { Test-Install }
    "All" { Test-Static; Test-Install }
}
