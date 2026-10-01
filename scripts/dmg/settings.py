# dmgbuild layout for Cove's disk image. Positions match scripts/dmg/render-background.py.
# Usage: dmgbuild -s scripts/dmg/settings.py -D app=PATH/Cove.app -D background=PATH.tiff -D icon=PATH.icns Cove OUT.dmg
import os.path

application = defines["app"]  # noqa: F821 (provided by dmgbuild)
files = [application]
symlinks = {"Applications": "/Applications"}
volume_name = "Cove"
format = "UDZO"
filesystem = "HFS+"
icon = defines.get("icon")  # noqa: F821
background = defines["background"]  # noqa: F821
window_rect = ((200, 140), (660, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {os.path.basename(application): (170, 210), "Applications": (490, 210)}
