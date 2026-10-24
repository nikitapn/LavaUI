import Foundation
import Testing

@testable import LavaShell

@Suite("Sound routes")
struct SoundRoutesTests {
    // A real laptop's outputs: a GPU's HDMI, the onboard card with speakers
    // and an empty headphone jack, and a Bluetooth headset.
    let hdmi = SoundDevice(
        name: "alsa_output.pci-0000_01_00.1.hdmi-stereo",
        description: "GA106 High Definition Audio Controller Digital Stereo (HDMI)",
        card: "GA106 High Definition Audio Controller", bus: "pci",
        ports: [SoundPort(name: "hdmi-output-0", description: "HDMI / DisplayPort", availability: .yes)],
        activePort: "hdmi-output-0"
    )
    let analog = SoundDevice(
        name: "alsa_output.pci-0000_06_00.6.analog-stereo",
        description: "Ryzen HD Audio Controller Analog Stereo",
        card: "Ryzen HD Audio Controller", bus: "pci",
        ports: [
            SoundPort(name: "analog-output-speaker", description: "Speakers", availability: .unknown),
            SoundPort(name: "analog-output-headphones", description: "Headphones", availability: .no),
        ],
        activePort: "analog-output-speaker"
    )
    let headset = SoundDevice(
        name: "bluez_output.F4_9D_8A_36_C2_6D.1",
        description: "soundcore Space One Pro",
        card: "soundcore Space One Pro", bus: "bluetooth",
        ports: [SoundPort(name: "headset-output", description: "Headphones", availability: .yes)],
        activePort: "headset-output"
    )

    @Test("a card is named by its port, a headset by itself")
    func titles() {
        let rows = SoundRoutes.routes([hdmi, analog, headset], current: headset.name)
        #expect(rows.map(\.title) == ["HDMI / DisplayPort", "Speakers", "soundcore Space One Pro"])
        #expect(rows.map(\.subtitle) == [
            "GA106 High Definition Audio Controller", "Ryzen HD Audio Controller", "",
        ])
        #expect(rows.map(\.isCurrent) == [false, false, true])
        // One usable port each, already selected: nothing to switch.
        #expect(rows.allSatisfy { $0.port == nil })
    }

    @Test("a jack with something in it is a row of its own")
    func pluggedHeadphones() {
        var card = analog
        card.ports[1].availability = .yes
        let rows = SoundRoutes.routes([card], current: card.name)
        #expect(rows.map(\.title) == ["Speakers", "Headphones"])
        #expect(rows.map(\.port) == ["analog-output-speaker", "analog-output-headphones"])
        #expect(rows.map(\.isCurrent) == [true, false])
        #expect(Set(rows.map(\.id)).count == 2)
    }

    @Test("the one working port is selected along with its device")
    func unpluggedLeavesStalePort() {
        var card = analog
        card.activePort = "analog-output-headphones"
        let rows = SoundRoutes.routes([card], current: "other")
        #expect(rows.count == 1)
        #expect(rows[0].title == "Speakers")
        #expect(rows[0].port == "analog-output-speaker")
    }

    @Test("an output with every jack empty is hidden, unless it is playing")
    func emptyJacks() {
        var screenless = hdmi
        screenless.ports[0].availability = .no
        #expect(SoundRoutes.routes([screenless, headset], current: headset.name).map(\.device)
            == [headset.name])
        let rows = SoundRoutes.routes([screenless, headset], current: screenless.name)
        #expect(rows.map(\.device) == [screenless.name, headset.name])
        #expect(rows[0].isCurrent)
    }

    @Test("the same sink listed many times is one row")
    func duplicates() {
        let rows = SoundRoutes.routes(Array(repeating: hdmi, count: 35) + [headset], current: "")
        #expect(rows.map(\.device) == [hdmi.name, headset.name])
    }

    @Test("a device with no ports is named by its description")
    func portless() {
        let virtual = SoundDevice(name: "null", description: "Dummy Output")
        let rows = SoundRoutes.routes([virtual], current: "null")
        #expect(rows == [SoundRoute(
            device: "null", port: nil, title: "Dummy Output", subtitle: "", isCurrent: true
        )])
    }

    @Test("a stream is titled by its application, then its media")
    func streamTitle() {
        #expect(SoundStream(id: 1, app: "Google Chrome", media: "Playback").title == "Google Chrome")
        #expect(SoundStream(id: 2, app: "", media: "Playback").title == "Playback")
        #expect(SoundStream(id: 3, app: "", binary: "mpv").title == "mpv")
    }
}
