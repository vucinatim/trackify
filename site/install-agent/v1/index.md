# Trackify agent installation protocol V1

Status: V1 protocol

This versioned endpoint uses the same V1 trust boundary and steps as the [stable Trackify agent-installation endpoint](../). It remains stable for V1 installers even if the unversioned endpoint later advances.

No installation is available until the stable release manifest and signature exist and agree with a signed, notarized GitHub Release. When absent, stop without changing the machine.
