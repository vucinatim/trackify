# Trackify agent installation protocol V1

Status: V1 protocol

This versioned endpoint uses the same V1 trust boundary and steps as the [stable Trackify agent-installation endpoint](../). It remains stable for V1 installers even if the unversioned endpoint later advances.

No installation is available until the stable release manifest and Ed25519 signature exist and agree with an immutable GitHub Release. When absent, stop without changing the machine. The first install is trust-on-first-use from the public project; subsequent updates are pinned to the Sparkle key embedded in Trackify.
