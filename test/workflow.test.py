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

# Local backups: no caller input, and the retained steps cannot run.
for name in ("backup_database", "backup_assets"):
    check(name not in inputs, f"{name} should not be a deploy input")
deploy_text = (root / ".github" / "workflows" / "deploy.yml").read_text()
check("inputs.backup_" not in deploy_text, "deploy.yml should not read the removed backup inputs")
check(job["env"].get("SITEHOST_LOCAL_BACKUPS") == "disabled", "SITEHOST_LOCAL_BACKUPS must be disabled")
for name in ("Discard deploy backups", "Restore database and assets"):
    cond = str(by_name[name].get("if", ""))
    check(cond.lstrip().startswith("env.SITEHOST_LOCAL_BACKUPS == 'enabled'"), f"{name} must be behind SITEHOST_LOCAL_BACKUPS")
deploy_env = by_name["Deploy commit"]["env"]
for name in ("BACKUP_DATABASE", "BACKUP_ASSETS"):
    check(name not in deploy_env, f"Deploy commit should not send {name}")
    check(name not in by_name["Deploy commit"]["with"]["env_names"].split(), f"Deploy commit should not export {name}")
check(str(by_name["Warn when container_snapshot is off"]["if"]) == "inputs.container_snapshot == false", "the no-backup warning should only check container_snapshot")
check(by_name["Roll back container"]["env"]["RESTORE_SNAPSHOT_DATABASE"] == "true", "rollback must restore the snapshot database")

# SITEHOST_SERVICE is gone. The API container name is always SITEHOST_STACK.
for name in ("deploy.yml", "backup.yml", "restore.yml", "status.yml"):
    check("SITEHOST_SERVICE" not in (root / ".github" / "workflows" / name).read_text(), f"{name} should not set SITEHOST_SERVICE")

# The SiteHost API backup is on by default.
check(inputs["container_snapshot"]["default"] is True, "container_snapshot should default to true")

# Talaria: checked first, before any backup or file change.
check(order[0] == "Find Talaria key", "Find Talaria key must be the first step")
check(by_name["Find Talaria key"]["with"]["script"] == "talaria-resolve.sh", "Find Talaria key must run talaria-resolve.sh")
check(by_name["Find Talaria key"].get("id") == "talaria-key", "Find Talaria key must have id talaria-key")
check("continue-on-error" not in by_name["Find Talaria key"], "Find Talaria key handles its own errors")
check(order[1] == "Check Talaria keys", "Check Talaria keys must run right after the key lookup")
check_env = by_name["Check Talaria keys"].get("env", {})
for name in ("TALARIA_API_KEY", "TALARIA_URL"):
    # A step env would hide the value talaria-resolve.sh wrote to GITHUB_ENV.
    check(name not in check_env, f"Check Talaria keys must read the resolved {name}, not set its own")
    check(f"env.{name}" in deploy_env[name], f"Deploy commit must send the resolved {name}")
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
check("talaria_key_source" in action["outputs"], "action must expose the Talaria key source")

if errors:
    for e in errors:
        print(f"workflow test: {e}", file=sys.stderr)
    sys.exit(1)
print("workflow test passed")
