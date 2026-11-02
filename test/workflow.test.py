#!/usr/bin/env python3
"""Static checks on the reusable workflows.

Local backups stay in the file but cannot run. Talaria steps only run when the
key check says Talaria is on. The key check runs before any backup or deploy.
"""
import sys
from pathlib import Path

import yaml

root = Path(__file__).resolve().parent.parent
errors = []


def check(cond, msg):
    if not cond:
        errors.append(msg)


def load(name):
    return yaml.safe_load((root / ".github" / "workflows" / name).read_text())


deploy = load("deploy.yml")
inputs = deploy[True]["workflow_call"]["inputs"]  # PyYAML reads `on` as True.
job = deploy["jobs"]["deploy"]
steps = job["steps"]
by_name = {s["name"]: s for s in steps}
order = [s["name"] for s in steps]

# Local backups: inputs kept for old callers, ignored, and the steps cannot run.
check(inputs["backup_database"]["default"] is False, "backup_database should default to false")
check(inputs["backup_assets"]["default"] is False, "backup_assets should default to false")
check("Ignored" in inputs["backup_database"]["description"], "backup_database should say it is ignored")
check(job["env"].get("SITEHOST_LOCAL_BACKUPS") == "disabled", "SITEHOST_LOCAL_BACKUPS must be disabled")
for name in ("Discard deploy backups", "Restore database and assets"):
    cond = str(by_name[name].get("if", ""))
    check(cond.lstrip().startswith("env.SITEHOST_LOCAL_BACKUPS == 'enabled'"), f"{name} must be behind SITEHOST_LOCAL_BACKUPS")
deploy_env = by_name["Deploy commit"]["env"]
check(deploy_env["BACKUP_DATABASE"] == "false", "Deploy commit must send BACKUP_DATABASE=false")
check(deploy_env["BACKUP_ASSETS"] == "false", "Deploy commit must send BACKUP_ASSETS=false")
check(by_name["Roll back container"]["env"]["RESTORE_SNAPSHOT_DATABASE"] == "true", "rollback must restore the snapshot database")

# The SiteHost API backup is on by default.
check(inputs["container_snapshot"]["default"] is True, "container_snapshot should default to true")

# Talaria: checked first, before any backup or file change.
check(order[0] == "Check Talaria keys", "Check Talaria keys must be the first step")
check(by_name["Check Talaria keys"]["with"]["script"] == "talaria-check.sh", "Check Talaria keys must run talaria-check.sh")
talaria_steps = [
    "Checkout code",
    "Setup Node",
    "Install dependencies",
    "Build the source map",
    "Upload source maps",
    "Set TALARIA_RELEASE",
    "Wait for container restart",
    "Stage rewritten script",
    "Install rewritten script",
]
for name in talaria_steps:
    check("steps.talaria.outputs.talaria_enabled == 'true'" in str(by_name[name].get("if", "")), f"{name} must only run when Talaria is on")
check("Check source map key" not in by_name, "the old source map key step should be gone")
check("talaria_reachable == 'false'" in str(by_name["Upload source maps"].get("continue-on-error", "")), "source map upload should be best effort in an outage")
check("steps.talaria.outputs.talaria_enabled == 'true'" in deploy_env["TALARIA_API_KEY"], "TALARIA_API_KEY must only reach the container when Talaria is on")
check("TALARIA_ENABLED" in by_name["Deploy commit"]["with"]["env_names"].split(), "Deploy commit must export TALARIA_ENABLED")
check("TALARIA_REACHABLE" in by_name["Deploy commit"]["with"]["env_names"].split(), "Deploy commit must export TALARIA_REACHABLE")

# Backup and restore workflows take no Talaria input at all.
for name in ("backup.yml", "restore.yml"):
    text = (root / ".github" / "workflows" / name).read_text()
    check("TALARIA_" not in text, f"{name} should not need Talaria")

restore = load("restore.yml")
rin = restore[True]["workflow_call"]["inputs"]
check(rin["snapshot_id"]["required"] is False and rin["snapshot_id"]["default"] == "", "restore snapshot_id should be optional")
rsteps = [s["name"] for s in restore["jobs"]["restore"]["steps"]]
check(rsteps.index("Find newest snapshot") < rsteps.index("Start container backup"), "restore must pick the newest snapshot before its safety backup")

# The SSH action accepts the new script and exposes its outputs.
action = yaml.safe_load((root / "actions" / "ssh" / "action.yml").read_text())
check("talaria_enabled" in action["outputs"] and "talaria_reachable" in action["outputs"], "action must expose the Talaria outputs")

if errors:
    for e in errors:
        print(f"workflow test: {e}", file=sys.stderr)
    sys.exit(1)
print("workflow test passed")
