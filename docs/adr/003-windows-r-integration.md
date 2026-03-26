# ADR-003: Windows R Integration via PowerShell Bridge

**Date:** 2026-03-26  
**Status:** Accepted  
**Author:** Wayne

## Context

The `up` maintenance command includes R package updates as step [5/13]. However, running R from WSL presents challenges:

1. **Windows R installation** - R is installed at `C:\Program Files\R\R-4.x.x\`
2. **Lock directory issues** - WSL cannot properly lock Windows filesystem directories
3. **Permission mismatch** - Windows ACLs don't map cleanly to Unix permissions
4. **Path translation** - `/mnt/c/Program Files/R/...` vs `C:\Program Files\R\...`

Initial approach (direct Rscript from WSL):
```bash
/mnt/c/Program\ Files/R/R-*/bin/x64/Rscript.exe -e 'update.packages()'
```

This failed with:
```
ERROR: failed to lock directory 'C:\Program Files\R\R-4.5.2\library'
```

## Decision

Use a **PowerShell bridge script** that runs natively in Windows:

### Architecture
```
WSL (up command)
    ↓ calls
powershell.exe -File update-r-packages.ps1
    ↓ runs natively in Windows
Rscript.exe -e 'update.packages()'
    ↓ returns
SUCCESS/ERROR output parsed by WSL
```

### Implementation

**File:** `C:\Programs\bat Files\update-r-packages.ps1`

```powershell
# Auto-detect R installation
$rPaths = Get-ChildItem "C:\Program Files\R" -Directory -Filter "R-*"
$rPath = $rPaths | Sort-Object Name -Descending | Select-Object -First 1
$rscript = Join-Path $rPath "bin\x64\Rscript.exe"

# Run update with Windows permissions
& $rscript -e "update.packages(ask=FALSE, checkBuilt=TRUE, Ncpus=4)"

# Return exit code for WSL to parse
if ($LASTEXITCODE -eq 0) {
    Write-Host "SUCCESS"
    exit 0
} else {
    Write-Host "ERROR: $LASTEXITCODE"
    exit 1
}
```

**WSL caller:** `scripts/08-maintenance.sh`

```bash
ps1_script="/mnt/c/Programs/bat Files/update-r-packages.ps1"
update_output=$(timeout 300 powershell.exe -NoProfile -NonInteractive \
    -File "$ps1_script" 2>&1)

if [[ "$update_output" == *"SUCCESS"* ]]
then
    __tac_line "[5/13] R Packages" "[UPDATED]" "$C_Success"
elif [[ "$update_output" == *"failed to lock directory"* ]]
then
    __tac_line "[5/13] R Packages" "[SKIP - Run from Windows]" "$C_Dim"
fi
```

## Consequences

### Positive
- **Proper permissions** - Windows process accesses Windows filesystem natively
- **No lock errors** - Windows R can lock its own library directory
- **Clean error handling** - Exit codes and output parsing work reliably
- **User feedback** - Clear messages about what's happening

### Negative
- **Extra dependency** - Requires PowerShell to be available (always true on Windows)
- **Additional file** - Must maintain PS1 script alongside bash code
- **Slight overhead** - PowerShell startup adds 1-2 seconds

### Alternative Approaches Considered

1. **Run R update from Windows Task Scheduler**
   - Rejected: Too complex, requires user setup

2. **Skip R updates in WSL**
   - Rejected: Maintenance should be comprehensive

3. **Use WSLg or interop to run R directly**
   - Rejected: Same lock issues, no benefit

## References
- PowerShell script: `C:\Programs\bat Files\update-r-packages.ps1`
- WSL caller: `scripts/08-maintenance.sh` [5/13] R Packages step
- Related: `scripts/08-maintenance.sh` Docker/NPM cleanup steps
