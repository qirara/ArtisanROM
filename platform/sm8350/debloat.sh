# SPDX-License-Identifier: GPL-3.0-or-later

# Debloat list for Qualcomm Snapdragon 888 devices (sm8350)
# - Add entries inside the specific partition containing that file (<PARTITION>_DEBLOAT+="")
# - DO NOT add the partition name at the start of any entry (eg. "/system/dpolicy_system")
# - DO NOT add a slash at the start of any entry (eg. "/dpolicy_system")

# Wi-Fi overlays for the source (Qualcomm FastConnect) Wi-Fi chip, sm8350 devices use a Broadcom one
SYSTEM_DEBLOAT+="
system/app/WifiRROverlayAppH2E
system/app/WifiRROverlayAppLls
system/app/WifiRROverlayAppRSNO
system/app/WifiRROverlayAppSaeUpgradeOffload
"

# Mobile AP overlays for features not supported by the target Wi-Fi chip
PRODUCT_DEBLOAT+="
overlay/SoftapOverlay6GHz
overlay/SoftapOverlayDualAp
overlay/SoftapOverlayOWE
"

# mAFPC
SYSTEM_DEBLOAT+="
system/bin/mafpc_write
"

# GameDriver
SYSTEM_DEBLOAT+="
system/priv-app/GameDriver-SM8650
"

# system_ext clean-up
SYSTEM_EXT_DEBLOAT+="
etc/permissions/com.qti.location.sdk.xml
etc/permissions/com.qualcomm.location.xml
etc/permissions/privapp-permissions-com.qualcomm.location.xml
framework/com.qti.location.sdk.jar
priv-app/com.qualcomm.location
"

# vendor clean-up
# - The stock vendor declares the schedtune (stune) cgroup controller, but the 5.4 kernel only has uclamp.
#   Android 16 QPR2 init aborts SetupCgroups when a non-optional controller fails to mount, so the cgroup v2
#   system/app hierarchy is never created and apexd-bootstrap cannot start ("bootstrap-apexd-failed" bootloop).
#   This file only declares schedtune, the vendor task profiles do not use it.
VENDOR_DEBLOAT+="
etc/cgroups.json
"
