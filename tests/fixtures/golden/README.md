# Golden Fixtures

This folder stores baseline command-output fixtures captured from the Bash
implementation for parity checks during PowerShell translation.

## Generate Fixtures

From repo root:

```bash
tools/capture-golden-fixtures.sh
```

Optional output directory:

```bash
tools/capture-golden-fixtures.sh --out tests/fixtures/golden
```

## File Format

For each fixture name `<name>`:

- `<name>.txt` contains captured stdout/stderr output.
- `<name>.meta` contains command, UTC timestamp, host, and exit code.

## Normalization Guidance

Before diffing Bash vs PowerShell outputs, normalize dynamic fields such as:

- Timestamps and dates
- Cache age indicators
- Hostname-specific values
- Environment-specific paths
- Runtime percentages and temperatures

Keep semantic sections, labels, and success/failure meaning identical.
