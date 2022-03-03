// https://www.kernel.org/doc/html/latest/usb/usbip_protocol.html


const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const net = std.net;

const log = std.log;

fn hexdump(buf: []u8) void {
    const line_width = 16;

    const stdout = std.io.getStdOut().writer();

    var i: usize = 0;
    while (i < buf.len) : (i += line_width) {
        stdout.print("{x:0>6}\t", .{i}) catch unreachable;

        const end = @minimum(line_width, buf.len - i);

        for (buf[i..i+end]) |chr| {
            stdout.print("{x:0>2} ", .{chr}) catch unreachable;
        }
        stdout.print("\n", .{}) catch unreachable;
    }
}

const Command = enum(u16) {
    req_devlist = 0x8005,
    rep_devlist = 0x0005,
    req_import = 0x8003,
    rep_import = 0x0003,
};

const USBIPHeader = packed struct {
    version: u16,
    command: u16,
    status: u32,
};

const USBIPHeaderBasic = packed struct {
    command: u32,
    seqnum: u32,
    devid: u32,
    direction: u32,
    ep: u32,
};

const USBIPCmdSubmit = struct {
    const Packet = packed struct {
        header: USBIPHeaderBasic,
        transfer_flags: u32,
        transfer_buffer_length: u32,
        start_frame: u32,
        number_of_packets: u32,
        interval: u32,
        setup: u64,
    };

    pkt: Packet,
    transfer_buffer: []u8,
    iso_packet_descriptor: []u8,
};

const Device = struct {
    const Packet = packed struct {
        path: [256]u8,
        busid: [32]u8,
        busnum: u32,
        devnum: u32,
        speed: u32,
        idVendor: u16,
        idProduct: u16,
        bcdDevice: u16,
        bDeviceClass: u8,
        bDeviceSubClass: u8,
        bDeviceProtocol: u8,
        bConfigurationValue: u8,
        bNumConfigurations: u8,
        bNumInterfaces: u8,
    };

    pkt: Packet,
    interfaces: []const Interface,
};

const Interface = packed struct {
    bInterfaceClass: u8,
    bInterfaceSubClass: u8,
    bInterfaceProtocol: u8,
    _padding: u8 = 0,
};

const Configuration = packed struct {
    bLength: u8,
    bDescriptorType: u8,
    wTotalLength: u16,
    bNumInterfaces: u8,
    bConfigurationValue: u8,
    iConfiguration: u8,
    bmAttributes: u8,
    bMaxPower: u8,
};

fn pack(writer: anytype, item: anytype) !void {
    const T = @TypeOf(item);

    switch (@typeInfo(T)) {
        .Int => try writer.writeIntBig(T, item),

        .Array => |array_info| switch (array_info.child) {
            u8 => _ = try writer.write(&item),
            else => {
                for (item) |el| {
                    try pack(writer, el);
                }
            },
        },

        .Struct => |struct_info| {
            inline for (struct_info.fields) |field| {
                try pack(writer, @field(item, field.name));
            }
        },

        .Pointer => |pointer_info| switch (pointer_info.size) {
            .Slice => for (item) |el| {
                try pack(writer, el);
            },

            else => @compileError("Packing not implemented for non-Slice pointers."),
        },

        else => @compileError("Packing not implemented for type " ++ T),
    }
}

fn unpack(comptime T: type, reader: anytype) !T {
    const buf = try reader.readBytesNoEof(@sizeOf(T));
    var out = @bitCast(T, buf);
    std.mem.bswapAllFields(T, &out);
    return out;
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(alloc);

    var server = net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();

    try server.listen(try net.Address.parseIp("0.0.0.0", 3240));

    var mydaq = Device {
        .pkt = .{
            .path = [_]u8{0} ** 256,
            .busid = [_]u8{0} ** 32,
            .busnum = 1,
            .devnum = 2,
            .speed = 2,
            .idVendor = 0x3923,
            .idProduct = 0x755b,
            .bcdDevice = 0x0003,
            .bDeviceClass = 0xff,
            .bDeviceSubClass = 0,
            .bDeviceProtocol = 0xff,
            .bConfigurationValue = 1,
            .bNumConfigurations = 1,
            .bNumInterfaces = 1,
        },
        .interfaces = &.{
            .{
                .bInterfaceClass = 0xff,
                .bInterfaceSubClass = 0,
                .bInterfaceProtocol = 0xff,
            },
        },
    };
    std.mem.copy(u8, &mydaq.pkt.path, "/sys/devices/pci0000:00/0000:00:01.2/usb1/1-1");
    std.mem.copy(u8, &mydaq.pkt.busid, "1-1");

    const configuration = Configuration{
        .bLength = 9,
        .bDescriptorType = 4,
        .wTotalLength = 0x0089,
        .bNumInterfaces = 1,
        .bConfigurationValue = 1,
        .iConfiguration = 0,
        .bmAttributes = 0x80,
        .bMaxPower = 250,
    };

    const devices = [_]Device{ mydaq };

    while (true) {
        buf.clearRetainingCapacity();
        var writer = buf.writer(alloc);

        var client = try server.accept();
        defer client.stream.close();
        var reader = client.stream.reader();

        const header = try unpack(USBIPHeader, reader);

        log.info("Connection from {} with USBIP version {}", .{client.address, header.version});

        switch (@intToEnum(Command, header.command)) {
            .req_devlist => {
                log.debug("OP_REQ_DEVLIST", .{});
                log.info("Client sent request for the device list.", .{});

                const rep_header = USBIPHeader {
                    .version = 0x0111,
                    .command = @enumToInt(Command.rep_devlist),
                    .status = 0,
                };

                try pack(writer, rep_header);
                try writer.writeIntBig(u32, devices.len);
                for (devices) |dev| {
                    try pack(writer, dev);
                }

                hexdump(buf.items);

                _ = try client.stream.write(buf.items);
            },

            .req_import => {
                log.debug("OP_REQ_IMPORT", .{});

                const busid = try reader.readBytesNoEof(32);

                log.info("Client sent request to attach to bus {s}.", .{busid});

                const rep_header = USBIPHeader {
                    .version = 0x0111,
                    .command = @enumToInt(Command.rep_import),
                    .status = 0,
                };

                try pack(writer, rep_header);
                try pack(writer, devices[0].pkt);

                //try pack(writer, configuration);
                _ = configuration;

                hexdump(buf.items);

                _ = try client.stream.write(buf.items);

                var submit = USBIPCmdSubmit {
                    .pkt = try unpack(USBIPCmdSubmit.Packet, reader),
                    .transfer_buffer = undefined,
                    .iso_packet_descriptor = undefined,
                };

                log.debug("submit msg: {}", .{submit});

                var tmp: [128]u8 = undefined;
                const count = try reader.read(&tmp);
                log.debug("Count: {}", .{count});
                hexdump(&tmp);
            },

            else => {
                log.warn("Unhandled message from client: {}", .{header});
            }
        }
    }
}
