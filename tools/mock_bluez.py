#!/usr/bin/env python3
"""A BlueZ of our own, on a private bus, for Tests/LavaBluetoothTests.

    python3 -m venv --system-site-packages /tmp/lava-bt-venv
    /tmp/lava-bt-venv/bin/pip install python-dbusmock
    /tmp/lava-bt-venv/bin/python tools/mock_bluez.py /tmp/lbt

starts a dbus-daemon at /tmp/lbt/bus (keep the path short: a socket name
has a 108-byte limit) and python-dbusmock's bluez5 template on it as the
*system* bus, with one adapter that knows four devices: "Headphones"
(paired, connected, 80% battery), "Mouse" (paired, asleep), and two a
search has found, "Speaker" (near) and "Phone" (far). Then, in another
shell:

    LAVA_BT_TEST_BUS=$(cat /tmp/lbt/address) \\
        swift test --filter LavaBluetoothTests

One run per mock: the tests pair, connect and forget, so start a fresh one
before running them again.

Nothing here touches the machine's own Bluetooth: the tests point
`DBUS_SYSTEM_BUS_ADDRESS` at this bus, and nothing else is on it. The
template's Pair never calls an agent, so the agent tests call it through
the bus themselves (`lava_bt_test_call_agent`) — the same dispatch
bluetoothd's call would take.

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
        [sys.executable, "-m", "dbusmock", "--template", "bluez5", "--system"], env=env)

    import dbus
    bus = dbus.bus.BusConnection(address)
    for _ in range(100):
        if bus.name_has_owner("org.bluez"):
            break
        time.sleep(0.05)
    m = dbus.Interface(bus.get_object("org.bluez", "/"), "org.bluez.Mock")

    def mocked(path):
        return dbus.Interface(bus.get_object("org.bluez", path), "org.freedesktop.DBus.Mock")

    m.AddAdapter("hci0", "lava-test")
    adapter = "/org/bluez/hci0"
    # The template's StartDiscovery reads a filter nobody has set.
    mocked(adapter).AddProperty("org.bluez.Adapter1", "DiscoveryFilter", dbus.String(""))

    def device(address, name, icon, rssi=None):
        path = m.AddDevice("hci0", address, name)
        props = {"Icon": dbus.String(icon)}
        if rssi is not None:
            props["RSSI"] = dbus.Int16(rssi)
        mocked(path).UpdateProperties("org.bluez.Device1", props)
        return path

    headphones = device("11:22:33:44:55:01", "Headphones", "audio-headset")
    m.PairDevice("hci0", "11:22:33:44:55:01")
    m.ConnectDevice("hci0", "11:22:33:44:55:01")
    mocked(headphones).AddProperties("org.bluez.Battery1", {"Percentage": dbus.Byte(80)})

    device("11:22:33:44:55:02", "Mouse", "input-mouse")
    m.PairDevice("hci0", "11:22:33:44:55:02")

    device("11:22:33:44:55:03", "Speaker", "audio-card", rssi=-50)
    device("11:22:33:44:55:04", "Phone", "phone", rssi=-82)

    with open(os.path.join(base, "address"), "w") as f:
        f.write(address)
    print("BlueZ mock on", address, flush=True)

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
