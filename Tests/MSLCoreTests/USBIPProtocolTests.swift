import XCTest
@testable import MSLCore

/// USB/IP's wire format is the one part of passthrough with no second
/// opinion: `vhci_hcd` reads these bytes with a fixed-offset struct cast
/// and a wrong field silently becomes a different field. A guest will
/// enumerate a device whose descriptors are byte-swapped - it just lists
/// the wrong vendor - so "it worked once" is not evidence the encoder is
/// right.
///
/// These tests pin the two endiannesses against each other, which is where
/// the real hazard is: USB/IP's own headers are **big**-endian while the
/// USB descriptors they carry are **little**-endian.
final class USBIPProtocolTests: XCTestCase {

    /// Builds a 48-byte CMD_SUBMIT the way the kernel would.
    private func submitHeader(seqnum: UInt32, endpoint: UInt32, directionIn: Bool,
                              length: Int32, setup: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        func be(_ value: UInt32) {
            bytes.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24),
                                      UInt8(truncatingIfNeeded: value >> 16),
                                      UInt8(truncatingIfNeeded: value >> 8),
                                      UInt8(truncatingIfNeeded: value)])
        }
        be(1)                                   // USBIP_CMD_SUBMIT
        be(seqnum)
        be(0x0001)                              // devid
        be(directionIn ? 1 : 0)
        be(endpoint)
        be(0)                                   // transfer_flags
        be(UInt32(bitPattern: length))
        be(0)                                   // start_frame
        be(UInt32(bitPattern: -1))              // number_of_packets: non-iso
        be(0)                                   // interval
        bytes.append(contentsOf: setup)
        return bytes
    }

    func testDecodesACommandSubmitHeader() {
        // GET_DESCRIPTOR(DEVICE), the very first thing a guest asks.
        let setup: [UInt8] = [0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x40, 0x00]
        let bytes = submitHeader(seqnum: 13, endpoint: 0, directionIn: true, length: 64, setup: setup)
        XCTAssertEqual(bytes.count, usbipHeaderSize)
        let request = bytes.withUnsafeBufferPointer { USBIPRequest(header: $0.baseAddress!) }
        guard let request else { return XCTFail("a well-formed CMD_SUBMIT did not decode") }
        XCTAssertEqual(request.command, .submit)
        XCTAssertEqual(request.seqnum, 13)
        XCTAssertEqual(request.direction, .in)
        XCTAssertEqual(request.endpoint, 0)
        XCTAssertEqual(request.transferBufferLength, 64)
        XCTAssertTrue(request.isControl)

        // `number_of_packets` is -1 for every non-isochronous URB, so a
        // `!= 0` test would route all of them down the iso path.
        XCTAssertEqual(request.numberOfPackets, -1)
        XCTAssertFalse(request.isIsochronous)

        // The setup packet is little-endian, unlike the header around it.
        let decoded = request.controlSetup
        XCTAssertEqual(decoded?.bmRequestType, 0x80)
        XCTAssertEqual(decoded?.bRequest, USBStandardRequest.getDescriptor.rawValue)
        XCTAssertEqual(decoded?.wValue, 0x0100)
        XCTAssertEqual(decoded?.wLength, 64)
        XCTAssertEqual(decoded?.descriptorType, USBDescriptorType.device.rawValue)
        XCTAssertEqual(decoded?.descriptorIndex, 0)
        XCTAssertTrue(decoded?.isDeviceToHost == true)
        XCTAssertEqual(decoded?.type, 0, "a standard request")
    }

    func testRejectsAReplyCommandArrivingFromTheGuest() {
        // RET_SUBMIT is host→guest only. Decoding one would mean the stream
        // has desynchronised, and reading on would produce garbage URBs.
        var bytes = submitHeader(seqnum: 1, endpoint: 0, directionIn: true, length: 0,
                                 setup: Array(repeating: 0, count: 8))
        bytes[3] = 3   // USBIP_RET_SUBMIT
        XCTAssertNil(bytes.withUnsafeBufferPointer { USBIPRequest(header: $0.baseAddress!) })
    }

    func testRejectsAnUnknownDirection() {
        var bytes = submitHeader(seqnum: 1, endpoint: 0, directionIn: true, length: 0,
                                 setup: Array(repeating: 0, count: 8))
        bytes[15] = 7   // neither USBIP_DIR_OUT nor USBIP_DIR_IN
        XCTAssertNil(bytes.withUnsafeBufferPointer { USBIPRequest(header: $0.baseAddress!) })
    }

    func testReplyHeaderIsExactlyFortyEightBytesAndBigEndian() {
        let bytes = submitHeader(seqnum: 0x1234_5678, endpoint: 0, directionIn: true, length: 18,
                                 setup: [0x80, 0x06, 0x00, 0x01, 0, 0, 18, 0])
        let request = bytes.withUnsafeBufferPointer { USBIPRequest(header: $0.baseAddress!) }!
        let payload = Data([0x12, 0x01, 0x00, 0x02])
        let wire = USBIPReply.submit(to: request, status: 0, payload: payload).encode()

        XCTAssertEqual(wire.count, usbipHeaderSize + payload.count)
        XCTAssertEqual(Array(wire[0..<4]), [0, 0, 0, 3], "RET_SUBMIT")
        XCTAssertEqual(Array(wire[4..<8]), [0x12, 0x34, 0x56, 0x78], "seqnum, big-endian")
        XCTAssertEqual(Array(wire[12..<16]), [0, 0, 0, 1], "direction in")
        XCTAssertEqual(Array(wire[20..<24]), [0, 0, 0, 0], "status 0")
        XCTAssertEqual(Array(wire[24..<28]), [0, 0, 0, 4], "actual_length tracks the payload")
        XCTAssertEqual(Array(wire[48...]), Array(payload))
    }

    func testAnOutReplyCarriesNoPayload() {
        // A write's data went *to* the device; echoing it back would push
        // bytes the guest reads as the next URB's header.
        let bytes = submitHeader(seqnum: 9, endpoint: 2, directionIn: false, length: 4,
                                 setup: Array(repeating: 0, count: 8))
        let request = bytes.withUnsafeBufferPointer { USBIPRequest(header: $0.baseAddress!) }!
        let wire = USBIPReply.submit(to: request, status: 0, payload: Data([1, 2, 3, 4])).encode()
        XCTAssertEqual(wire.count, usbipHeaderSize)
    }

    func testStallIsMinusEPIPE() {
        // The kernel stores this straight into `urb->status`, where it has
        // to be Linux's -EPIPE and not an IOKit code.
        XCTAssertEqual(USBIPStatus.stall, -32)
        XCTAssertEqual(USBIPStatus.noDevice, -19)
    }

    func testDescriptorsAreLittleEndian() {
        // The opposite byte order to the header that carries them. Getting
        // this backwards gives a device that enumerates with its vendor ID
        // reversed - 0x0912 instead of 0x1209 - and no error anywhere.
        var builder = USBDescriptorBuilder()
        builder.u16(0x1209)
        XCTAssertEqual(builder.bytes, [0x09, 0x12])

        let string = USBDescriptorBuilder.string("MSL")
        XCTAssertEqual(Array(string), [8, 0x03, 0x4D, 0x00, 0x53, 0x00, 0x4C, 0x00])

        let languages = USBDescriptorBuilder.languageIDs()
        XCTAssertEqual(Array(languages), [4, 0x03, 0x09, 0x04], "0x0409, US English")
    }

    // MARK: - The synthetic device

    private func ask(_ device: SyntheticUSBDevice, bmRequestType: UInt8, bRequest: UInt8,
                     wValue: UInt16, wIndex: UInt16 = 0, wLength: UInt16) -> (Int32, Data) {
        let setup: [UInt8] = [
            bmRequestType, bRequest,
            UInt8(truncatingIfNeeded: wValue), UInt8(truncatingIfNeeded: wValue >> 8),
            UInt8(truncatingIfNeeded: wIndex), UInt8(truncatingIfNeeded: wIndex >> 8),
            UInt8(truncatingIfNeeded: wLength), UInt8(truncatingIfNeeded: wLength >> 8),
        ]
        let bytes = submitHeader(seqnum: 1, endpoint: 0, directionIn: bmRequestType & 0x80 != 0,
                                 length: Int32(wLength), setup: setup)
        let request = bytes.withUnsafeBufferPointer { USBIPRequest(header: $0.baseAddress!) }!
        var result: (Int32, Data) = (-1, Data())
        device.submit(request) { result = ($0.status, $0.payload) }
        return result
    }

    func testSyntheticDeviceDescriptorMatchesWhatAGuestEnumerated() {
        // These exact bytes are what made a guest print
        // "idVendor=1209, idProduct=4d53" - the end-to-end proof that the
        // whole transport is wired up correctly. Pinned so a later edit
        // cannot quietly change the device's identity.
        let device = SyntheticUSBDevice()
        let (status, data) = ask(device, bmRequestType: 0x80, bRequest: 0x06, wValue: 0x0100, wLength: 64)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(data.count, 18, "a device descriptor is 18 bytes")
        XCTAssertEqual(data[0], 18)
        XCTAssertEqual(data[1], USBDescriptorType.device.rawValue)
        XCTAssertEqual(UInt16(data[8]) | (UInt16(data[9]) << 8), SyntheticUSBDevice.vendorID)
        XCTAssertEqual(UInt16(data[10]) | (UInt16(data[11]) << 8), SyntheticUSBDevice.productID)
        XCTAssertEqual(data[17], 1, "one configuration")
    }

    func testConfigurationTotalLengthCoversTheInterface() {
        // A `wTotalLength` that stops at the configuration descriptor makes
        // the kernel read a truncated tree and reject the device.
        let device = SyntheticUSBDevice()
        let (status, data) = ask(device, bmRequestType: 0x80, bRequest: 0x06, wValue: 0x0200, wLength: 255)
        XCTAssertEqual(status, 0)
        let total = UInt16(data[2]) | (UInt16(data[3]) << 8)
        XCTAssertEqual(Int(total), data.count)
        XCTAssertEqual(total, 18, "9 configuration + 9 interface")
        XCTAssertEqual(data[9 + 1], USBDescriptorType.interface.rawValue)
    }

    func testNeverReturnsMoreThanTheHostAskedFor() {
        // A device that overruns the host's buffer is a protocol violation,
        // and the guest's first request deliberately asks for only 8 bytes.
        let device = SyntheticUSBDevice()
        let (status, data) = ask(device, bmRequestType: 0x80, bRequest: 0x06, wValue: 0x0100, wLength: 8)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(data.count, 8)
    }

    func testUnsupportedDescriptorStallsRatherThanFailing() {
        // The kernel asks for a BOS descriptor it is perfectly happy not to
        // get. A stall is "no"; anything else reads as a broken device.
        let device = SyntheticUSBDevice()
        let (status, _) = ask(device, bmRequestType: 0x80, bRequest: 0x06,
                              wValue: UInt16(USBDescriptorType.bos.rawValue) << 8, wLength: 255)
        XCTAssertEqual(status, USBIPStatus.stall)
    }

    func testSetConfigurationIsAcknowledged() {
        let device = SyntheticUSBDevice()
        let (status, data) = ask(device, bmRequestType: 0x00, bRequest: 0x09, wValue: 0x0001, wLength: 0)
        XCTAssertEqual(status, 0)
        XCTAssertTrue(data.isEmpty, "a zero-length status stage")
    }

    func testStringDescriptorsAreTheOnesTheGuestPrinted() {
        let device = SyntheticUSBDevice()
        for (index, expected) in [(1, "MSL"), (2, "MSL Virtual Test Device"), (3, "MSL-SYNTH-0001")] {
            let (status, data) = ask(device, bmRequestType: 0x80, bRequest: 0x06,
                                     wValue: 0x0300 | UInt16(index), wIndex: 0x0409, wLength: 255)
            XCTAssertEqual(status, 0, "string \(index)")
            let text = String(decoding: data.dropFirst(2))
            XCTAssertEqual(text, expected)
        }
    }

    func testThereIsNothingOnAnyOtherEndpoint() {
        // The synthetic device advertises no endpoints, so a URB on one is
        // the guest being confused and must not be answered with success.
        let device = SyntheticUSBDevice()
        let bytes = submitHeader(seqnum: 1, endpoint: 1, directionIn: true, length: 64,
                                 setup: Array(repeating: 0, count: 8))
        let request = bytes.withUnsafeBufferPointer { USBIPRequest(header: $0.baseAddress!) }!
        var status: Int32 = 0
        device.submit(request) { status = $0.status }
        XCTAssertEqual(status, USBIPStatus.stall)
    }
}

private extension String {
    /// UTF-16LE, as USB string descriptors carry text.
    init(decoding bytes: Data) {
        var units: [UInt16] = []
        var iterator = bytes.makeIterator()
        while let low = iterator.next(), let high = iterator.next() {
            units.append(UInt16(low) | (UInt16(high) << 8))
        }
        self = String(decoding: units, as: UTF16.self)
    }
}
