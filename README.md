# JIRA Component Migration Tool

A robust bash automation script for migrating JIRA components between projects with conflict detection, backup, and detailed reporting.

## Overview

This tool automates the migration of JIRA components from one project to another (e.g., from RHOAISTRAT to RHAISTRAT), preserving component names, descriptions, and lead assignments. It includes safety features like dry-run mode, automatic backups, conflict detection, and comprehensive logging.

## Features

- **Dry Run Mode**: Preview migrations without making changes
- **Conflict Detection**: Automatically identifies and skips existing components
- **Automatic Backups**: Saves source component data before migration
- **Progress Tracking**: Real-time progress updates during migration
- **Component Mapping**: Generates CSV mapping of old to new component IDs
- **Detailed Reporting**: Complete logs and statistics for audit trails
- **Flexible Configuration**: Environment variables, CLI args, or interactive prompts
- **Rate Limit Protection**: Configurable delays between API calls

## Prerequisites

### Required Tools

- `curl` - for API communication
- `jq` - for JSON processing

**Installation:**

```bash
# macOS
brew install curl jq

# RHEL/CentOS/Fedora
sudo dnf install curl jq

# Ubuntu/Debian
sudo apt-get install curl jq
```

**Verify installation:**

```bash
curl --version
jq --version
```

### JIRA Credentials

You'll need a JIRA bot account with:
- **Read access** to the source project
- **Admin access** to the destination project (to create components)

**To create a JIRA Personal Access Token (PAT):**
1. Log into [JIRA](https://issues.redhat.com) with your bot account
2. Navigate to [Profile Settings](https://issues.redhat.com/secure/ViewProfile.jspa)
3. Select "Personal Access Tokens"
4. Click "Create token"
5. Copy and securely store the token (it will only be shown once!)

**Note:** This script uses Bearer token authentication. Your PAT will be used as a Bearer token in the `Authorization` header.

## Quick Start

### 1. Make Script Executable

```bash
chmod +x migrate-jira-components.sh
```

### 2. Set Your Token

```bash
export BOT_TOKEN="your-bearer-token-here"
```

### 3. Run Dry Run First

```bash
./migrate-jira-components.sh --dry-run
```

### 4. Review Results

```bash
cd jira_migration_*/
cat migration_report.txt
```

### 5. Run Actual Migration

```bash
cd ..
./migrate-jira-components.sh
```

## Usage

### Basic Usage

```bash
# Dry run (recommended first step)
./migrate-jira-components.sh --dry-run

# Actual migration
./migrate-jira-components.sh

# View help
./migrate-jira-components.sh --help
```

### Configuration Options

#### Option 1: Environment Variables (Recommended - Most Secure)

```bash
export BOT_TOKEN="your-bearer-token-here"
export SOURCE_PROJECT="RHOAISTRAT"  # Optional, defaults to RHOAISTRAT
export DEST_PROJECT="RHAISTRAT"     # Optional, defaults to RHAISTRAT
export JIRA_URL="https://issues.redhat.com"  # Optional
```

#### Option 2: Command Line Arguments

```bash
./migrate-jira-components.sh \
  --token "your-bearer-token-here" \
  --source "RHOAISTRAT" \
  --dest "RHAISTRAT"
```

#### Option 3: Interactive Prompts

```bash
# Script will prompt for the token if not provided
./migrate-jira-components.sh
```

### Advanced Options

```bash
./migrate-jira-components.sh \
  --jira-url "https://issues.redhat.com" \
  --token "your-bearer-token" \
  --source "RHOAISTRAT" \
  --dest "RHAISTRAT" \
  --delay 2 \              # Delay between API calls (seconds)
  --skip-backup \          # Skip backup step (not recommended)
  --dry-run                # Preview without making changes
```

## Common Scenarios

### First Time Migration

```bash
# 1. Set credentials
export BOT_TOKEN="your-bearer-token"

# 2. Dry run first
./migrate-jira-components.sh --dry-run

# 3. Review results
cd jira_migration_*/
cat migration_report.txt

# 4. If all looks good, run actual migration
cd ..
./migrate-jira-components.sh
```

### Custom Projects

```bash
# Migrate between different projects
./migrate-jira-components.sh \
  --source "PROJECT_A" \
  --dest "PROJECT_B" \
  --dry-run
```

### Faster Migration

```bash
# Reduce delay between API calls (use carefully to avoid rate limits)
./migrate-jira-components.sh --delay 1
```

### Background Migration

```bash
# For large migrations
nohup ./migrate-jira-components.sh > migration.log 2>&1 &

# Monitor progress
tail -f migration.log
```

## Output and Artifacts

Each migration creates a timestamped directory: `jira_migration_YYYYMMDD_HHMMSS/`

### Generated Files

| File | Description |
|------|-------------|
| `source_components.json` | Backup of all source components |
| `conflicts.txt` | List of components that already exist in destination |
| `component_mapping.csv` | Mapping of old component IDs to new IDs |
| `migration_log.txt` | Detailed log of each component migration |
| `migration_report.txt` | Summary statistics and results |

### Sample Migration Report

```
Migration Statistics
--------------------
Total Source Components: 25
Successfully Migrated: 22
Failed: 0
Skipped (duplicates): 3
```

### Sample Migration Log Output

```
[1/22] Processing: Dashboard
✓ SUCCESS: Created component (New ID: 12345)

[2/22] Processing: Authentication
⚠ SKIPPED: Component already exists in destination

[3/22] Processing: API Gateway
✓ SUCCESS: Created component (New ID: 12346)
```

## Migration Workflow

### What the Script Does

1. **Validates** credentials and project access
2. **Shows** configuration and asks for confirmation
3. **Backs up** all source components to JSON
4. **Detects** conflicts (components that already exist)
5. **Migrates** components one by one with progress updates
6. **Creates** mapping file (`old_id,new_id` for each component)
7. **Generates** detailed report and logs

### Dry Run Mode

The dry run performs all validation and detection steps WITHOUT creating any components:

- ✅ Tests your credentials
- ✅ Validates both projects exist
- ✅ Shows which components will be migrated
- ✅ Identifies conflicts
- ✅ Shows migration statistics
- ❌ **Does NOT create any components**

**Always run dry-run first!**

## Troubleshooting

### "Authentication failed"

**Cause**: Invalid credentials or expired token

**Fix**:
```bash
# Test credentials manually
curl -H "Authorization: Bearer your-bearer-token" \
  https://issues.redhat.com/rest/api/2/myself

# If this fails, regenerate your PAT
```

### "Source project RHOAISTRAT not found"

**Cause**: Project key is wrong or you don't have access

**Fix**:
```bash
# Verify project exists
curl -H "Authorization: Bearer your-bearer-token" \
  https://issues.redhat.com/rest/api/2/project/RHOAISTRAT

# Check project key is correct (case-sensitive!)
```

### "Command not found: jq"

**Cause**: Missing required tool

**Fix**:
```bash
# macOS
brew install jq

# RHEL/Fedora
sudo dnf install jq

# Ubuntu/Debian
sudo apt-get install jq
```

### "Permission denied" when running script

**Cause**: Script is not executable

**Fix**:
```bash
chmod +x migrate-jira-components.sh
```

### Rate limit exceeded

**Cause**: Too many API calls too quickly

**Fix**:
```bash
# Increase delay between calls
./migrate-jira-components.sh --delay 5
```

### Some components failed to migrate

**Steps**:
1. Check `migration_log.txt` for specific error messages
2. Look for lines starting with "FAILED"
3. Fix the underlying issue (permissions, API errors, etc.)
4. Manually create failed components in JIRA UI if needed

## Security Best Practices

1. **Never commit credentials** to git repositories
2. **Use environment variables** instead of command-line args (avoids bash history)
3. **Rotate Bearer tokens (PATs)** regularly
4. **Limit bot account permissions** to only what's needed
5. **Delete migration directories** after successful migration if they contain sensitive data

```bash
# Clean up after successful migration
rm -rf jira_migration_*/
```

**Note:** The script uses Bearer token authentication. Your Personal Access Token (PAT) is sent in the `Authorization: Bearer` header for all API requests.

## Post-Migration Checklist

- [ ] Verify all expected components appear in destination project
- [ ] Check component descriptions are preserved
- [ ] Save `component_mapping.csv` to safe location
- [ ] Archive migration logs for audit trail
- [ ] Update any documentation referencing old components
- [ ] Test creating an issue in destination project with new components
- [ ] Notify team members about new component structure

## Verification

After migration, verify components in JIRA UI:

1. Open [JIRA](https://issues.redhat.com)
2. Navigate to destination project (e.g., RHAISTRAT)
3. Go to **Project Settings → Components**
4. Verify migrated components appear correctly

**Direct URL**: `https://issues.redhat.com/projects/RHAISTRAT/components`

## Important Files to Save

**Critical**: Save the `component_mapping.csv` file for future issue/feature migrations!

```bash
# Copy mapping to safe location
cp jira_migration_*/component_mapping.csv ~/rhoai-to-rhai-mapping.csv

# Archive entire migration directory
cp -r jira_migration_*/ ~/jira-migration-backup/
```

This mapping is essential for maintaining component associations when migrating issues/features later.

## Next Steps

After successful component migration:

1. **Migrate Features/Issues**: Use the `component_mapping.csv` to migrate issues and update their component associations
2. **Update Automation**: Update JIRA automation rules, filters, or dashboards that reference old components
3. **Archive Old Project**: Consider whether source project components should be archived or deleted
4. **Update Documentation**: Update any team documentation referencing the old project

## Command Reference

```bash
# Basic dry run
export BOT_TOKEN="your-bearer-token"
./migrate-jira-components.sh --dry-run

# Actual migration
./migrate-jira-components.sh

# With command line token
./migrate-jira-components.sh --token "your-bearer-token" --dry-run

# With custom delay
./migrate-jira-components.sh --delay 3

# Skip backup (not recommended)
./migrate-jira-components.sh --skip-backup

# Custom projects
./migrate-jira-components.sh --source "PROJ1" --dest "PROJ2"

# View help
./migrate-jira-components.sh --help

# View latest results
cd jira_migration_*/
cat migration_report.txt
```

## Support

If you encounter issues:

1. Check the `migration_log.txt` file for detailed error messages
2. Review the `migration_report.txt` for statistics
3. Run the script with `--help` to see all options
4. Contact your JIRA administrator for permission issues
5. [Open an issue](https://github.com/your-org/your-repo/issues) on GitHub

---

**Remember**: Always run with `--dry-run` first to preview changes before doing the actual migration!
