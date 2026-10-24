#!/usr/bin/env python3
"""A NetworkManager of our own, on a private bus, for Tests/LavaNetworkTests.

    python3 -m venv --system-site-packages /tmp/lava-nm-venv
    /tmp/lava-nm-venv/bin/pip install python-dbusmock
    /tmp/lava-nm-venv/bin/python tools/mock_networkmanager.py /tmp/lnm

starts a dbus-daemon at /tmp/lnm/bus (keep the path short: a socket name
has a 108-byte limit) and python-dbusmock's NetworkManager template on it as
the *system* bus, with a Wi-Fi radio that sees three networks: "Home" (saved,
connected), "Neighbour" (WPA, not saved) and "Café" (open). Then, in another
shell:

    LAVA_NET_TEST_BUS=$(cat /tmp/lnm/address) \\
        swift test --filter LavaNetworkTests

One run per mock: the tests join Café and disconnect Home, so start a fresh
one before running them again.

Nothing here touches the machine's own NetworkManager or keyring: the tests
point both `DBUS_SYSTEM_BUS_ADDRESS` and `DBUS_SESSION_BUS_ADDRESS` at this
bus, and libnm and libsecret read those.

The secret agent is not asked through this bus. libnm will not register an
agent with a NetworkManager that root does not own ("Not validated as
NetworkManager service"), which a mock run by a user never is, so the agent
tests call `lava_net_test_get_secrets` instead — the same code from the
request on.

Ctrl+C (or SIGTERM) stops both.
"""

import os
import signal
import subprocess
import sys
import time


def main(base):
    os.makedirs(base, exist_ok=True)
    sock = os.path.join(base, "bus")
    if os.path.exists(sock):
        os.unlink(sock)
    address = "unix:path=" + sock
    daemon = subprocess.Popen(
        ["dbus-daemon", "--session", "--nofork", "--nopidfile", "--address=" + address])
    for _ in range(50):
        if os.path.exists(sock):
            break
        time.sleep(0.05)
    env = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=address)
    mock = subprocess.Popen(
        [sys.executable, "-m", "dbusmock", "--template", "networkmanager", "--system"], env=env)

    import dbus
    bus = dbus.bus.BusConnection(address)
    for _ in range(100):
        if bus.name_has_owner("org.freedesktop.NetworkManager"):
            break
        time.sleep(0.05)
    nm = bus.get_object("org.freedesktop.NetworkManager", "/org/freedesktop/NetworkManager")
    m = dbus.Interface(nm, "org.freedesktop.DBus.Mock")

    wifi = m.AddWiFiDevice("wlan0", "wlan0", 100)
    psk = 0x100  # the template knows key management, not ciphers
    m.AddAccessPoint(wifi, "home", "Home", "11:22:33:44:55:01", 2, 5180, 54000, 72, psk)
    m.AddAccessPoint(wifi, "neighbour", "Neighbour", "11:22:33:44:55:02", 2, 2437, 54000, 90, psk)
    m.AddAccessPoint(wifi, "cafe", "Café", "11:22:33:44:55:03", 2, 2412, 54000, 30, 0)
    conn = m.AddWiFiConnection(wifi, "home", "Home", "wpa-psk")
    m.AddActiveConnection([wifi], conn, "/org/freedesktop/NetworkManager/AccessPoint/home",
                          "activehome", 2)
    m.SetProperty("/org/freedesktop/NetworkManager", "org.freedesktop.NetworkManager",
                  "WirelessEnabled", dbus.Boolean(True))

    with open(os.path.join(base, "address"), "w") as f:
        f.write(address)
    print("NetworkManager mock on", address, flush=True)

    def stop(*_):
        mock.terminate()
        daemon.terminate()
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    mock.wait()
    daemon.terminate()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
