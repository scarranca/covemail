#!/usr/bin/env python3
"""Write public app configuration without copying user credentials into a release."""
import json
import base64
import os
from pathlib import Path
import plistlib
import re
import sys

version = os.environ.get("COVE_VERSION", "0.1.56")
build = os.environ.get("COVE_BUILD", "58")
if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"\d+", build):
    sys.exit("COVE_VERSION must be x.y.z and COVE_BUILD must be an integer.")
info = {
    "CFBundleName": "Cove", "CFBundleDisplayName": "Cove", "CFBundleIdentifier": "ai.cove.mac",
    "CFBundleExecutable": "Cove", "CFBundlePackageType": "APPL",
    "CFBundleIconFile": "Cove.icns",
    "CFBundleShortVersionString": version, "CFBundleVersion": build,
    "NSLocationUsageDescription": "Cove uses your approximate location to show weather on Home. Rounded coordinates are sent to MET Norway for the forecast.",
    "NSLocationWhenInUseUsageDescription": "Cove uses your approximate location to show weather on Home.",
    "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
}
if os.environ.get("COVE_DISTRIBUTION") == "1":
    update = json.loads((Path(__file__).resolve().parents[1] / "assets/update-config.json").read_text())
    if not update['feedURL'].startswith('https://') or len(base64.b64decode(update['publicEDKey'], validate=True)) != 32:
        sys.exit('Invalid public update configuration.')
    info.update(SUFeedURL=update['feedURL'], SUPublicEDKey=update['publicEDKey'],
                CoveUpdatesEnabled=True, SUEnableAutomaticChecks=True,
                SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
                SUScheduledCheckInterval=86400, SUEnableSystemProfiling=False,
                SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                SUEnableJavaScript=False)
cloud_url = os.environ.get("COVE_CLOUD_SYNC_URL")
if not cloud_url and os.environ.get("COVE_DISTRIBUTION") == "1":
    cloud_url = json.loads((Path(__file__).resolve().parents[1] / "assets/cloud-sync-config.json").read_text())["baseURL"]
if cloud_url:
    if not re.fullmatch(r"https://[a-z0-9-]+(?:\.[a-z0-9-]+)*\.run\.app", cloud_url):
        sys.exit("COVE_CLOUD_SYNC_URL must be the verified Cloud Run HTTPS origin.")
    info["CoveCloudSyncURL"] = cloud_url
source = os.environ.get("COVE_GOOGLE_OAUTH_FILE")
if source:
    try:
        installed = json.loads(Path(source).read_text())["installed"]
        client_id = installed["client_id"]
        client_secret = installed.get("client_secret", "")
        if not isinstance(client_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]+\.apps\.googleusercontent\.com", client_id):
            raise ValueError("invalid client ID")
        if not isinstance(client_secret, str) or any(c in client_secret for c in "\r\n\0"):
            raise ValueError("invalid desktop configuration")
        info["CoveGoogleClientID"] = client_id
        info["CoveGoogleClientSecret"] = client_secret
    except (KeyError, ValueError, OSError, TypeError):
        sys.exit("Provide a valid Google Desktop OAuth JSON download. Web clients and user credential files are not accepted.")
elif os.environ.get("COVE_DISTRIBUTION") == "1":
    sys.exit("Distribution builds require COVE_GOOGLE_OAUTH_FILE for one-click Gmail onboarding.")
with open(sys.argv[1], "wb") as output:
    plistlib.dump(info, output)
