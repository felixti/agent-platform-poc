#!/usr/bin/env python3
"""Build the Teams app package (manifest + icons) for one agent.

Usage: python3 teams-app/build.py agents/<employee>/<name>.yaml
Output: teams-app/dist/<employee>-<name>.zip  -> upload in Teams:
        Apps -> Manage your apps -> Upload an app -> Upload a custom app.
Reads appId from channels.msteams.appId (written after `tofu apply`, teams.tf).
No third-party deps (icons are drawn with zlib)."""
import json, re, struct, sys, uuid, zipfile, zlib
from pathlib import Path

def field(text, key):
    m = re.search(rf"^\s*{key}:\s*(\S+)", text, re.M)
    return m.group(1).strip('"') if m else None

def png(size, rgba_at):
    raw = b"".join(b"\x00" + b"".join(bytes(rgba_at(x, y, size)) for x in range(size)) for y in range(size))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

def ring(x, y, n):  # a simple "agent" mark: ring + dot
    c = (n - 1) / 2; d = ((x - c) ** 2 + (y - c) ** 2) ** 0.5
    return 0.30 * n <= d <= 0.40 * n or d <= 0.12 * n

color = lambda x, y, n: (255, 255, 255, 255) if ring(x, y, n) else (91, 109, 239, 255)
outline = lambda x, y, n: (255, 255, 255, 255) if ring(x, y, n) else (0, 0, 0, 0)

spec = Path(sys.argv[1]).read_text()
emp, name, app_id = field(spec, "employee"), field(spec, "name"), field(spec, "appId")
if not app_id:
    sys.exit("channels.msteams.appId missing: run tofu apply (infra/platform/teams.tf) first")
manifest = {
    "$schema": "https://developer.microsoft.com/en-us/json-schemas/teams/v1.23/MicrosoftTeams.schema.json",
    "manifestVersion": "1.23",
    "version": "1.0.0",
    "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"agent-platform/{emp}/{name}")),
    "name": {"short": f"{name} ({emp})", "full": f"Agent {name} of {emp}"},
    "developer": {"name": "agent-platform-poc", "websiteUrl": "https://github.com/felixti/agent-platform-poc",
                  "privacyUrl": "https://github.com/felixti/agent-platform-poc",
                  "termsOfUseUrl": "https://github.com/felixti/agent-platform-poc"},
    "description": {"short": f"{emp}'s always-on agent", "full": f"OpenClaw agent {name} for {emp}, running on the agent platform PoC."},
    "icons": {"outline": "outline.png", "color": "color.png"},
    "accentColor": "#5B6DEF",
    "bots": [{"botId": app_id, "scopes": ["personal", "team", "groupChat"], "isNotificationOnly": False,
              "supportsCalling": False, "supportsVideo": False, "supportsFiles": True}],
    "webApplicationInfo": {"id": app_id},
    "authorization": {"permissions": {"resourceSpecific": [
        {"name": n, "type": "Application"} for n in (
            "ChannelMessage.Read.Group", "ChannelMessage.Send.Group", "Member.Read.Group", "Owner.Read.Group",
            "ChannelSettings.Read.Group", "TeamMember.Read.Group", "TeamSettings.Read.Group", "ChatMessage.Read.Chat")]}},
}
out = Path(__file__).parent / "dist" / f"{emp}-{name}.zip"
out.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("manifest.json", json.dumps(manifest, indent=2))
    z.writestr("color.png", png(192, color))
    z.writestr("outline.png", png(32, outline))
print(out)
