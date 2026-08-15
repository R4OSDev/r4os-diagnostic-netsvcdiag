const r4os = @import("r4os");

const request_id_restart: u32 = 0x53564352;
const request_id_restart_test: u32 = 0x53564354;
const request_id_dns_probe: u32 = 0x53564344;
const request_id_stale_probe: u32 = 0x53564353;
const request_id_udp_probe: u32 = 0x53564355;
const request_id_tcp_probe: u32 = 0x53564350;
const restart_test_udp_port: u16 = 65019;
const restart_test_tcp_port: u16 = 65020;

const App = struct {
    sys: r4os.r4sys.Context,
    net: r4os.r4net.Context,

    fn init(r4_app: *r4os.App) ?App {
        return .{
            .sys = r4_app.system(),
            .net = r4_app.networkLowLevel() orelse return null,
        };
    }
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    const app = App.init(r4_app) orelse return r4os.abi.err_no_group;
    const args = trim(zSlice(app.sys.argsRaw()));

    if (args.len == 0 or equalsIgnoreCase(args, "STATUS")) return showStatus(&app);
    if (equalsIgnoreCase(args, "RESTARTTEST")) return runRestartDiagnostic(&app);
    if (equalsIgnoreCase(args, "RESTART")) {
        return runTextRequest(&app, r4os.abi.net_service_op_service_restart, request_id_restart, "NETSVC restart: ");
    }
    if (equalsIgnoreCase(args, "DRIVERLIFETEST") or equalsIgnoreCase(args, "DRIVERLIFECYCLETEST")) {
        return runDriverLifecycleDiagnostic(&app);
    }

    app.sys.println("Usage: NETSVC [STATUS|RESTART|RESTARTTEST|DRIVERLIFETEST]");
    return 1;
}

fn showStatus(app: *const App) i32 {
    app.sys.println("IPC network services");
    printChannel(app, r4os.abi.ipc_channel_net_dhcp, "net.dhcp");
    printChannel(app, r4os.abi.ipc_channel_net_dns, "net.dns");
    printChannel(app, r4os.abi.ipc_channel_net_tcp, "net.tcp");
    printChannel(app, r4os.abi.ipc_channel_net_udp, "net.udp");
    return 0;
}

fn printChannel(app: *const App, channel_id: u32, name: []const u8) void {
    var info: r4os.abi.IpcChannelInfo = .{};
    _ = app.net.ipcChannel(channel_id, &info);
    app.sys.write("  ");
    app.sys.write(name);
    app.sys.write(" channel=");
    app.sys.printU64(channel_id);
    app.sys.write(" queued=");
    app.sys.printU64(info.queued);
    app.sys.write("/");
    app.sys.printU64(info.queue_depth);
    app.sys.write(" handler=");
    app.sys.write(if (info.has_handler != 0) "yes" else "no");
    app.sys.write("\r\n");
}

fn runTextRequest(app: *const App, op: u16, request_id: u32, prefix: []const u8) i32 {
    var response: [r4os.abi.ipc_max_message_size]u8 = .{0} ** r4os.abi.ipc_max_message_size;
    var status: i32 = 0;
    const payload = requestBackend(app, r4os.abi.ipc_channel_net_dns, op, request_id, "", response[0..], &status) orelse return fail(app, "backend request failed");
    if (status != r4os.abi.net_service_result_ok) return fail(app, "backend returned error");

    app.sys.write(prefix);
    app.sys.write(payload);
    if (!endsWithNewline(payload)) app.sys.write("\r\n");
    return if (startsWith(payload, "ok")) 0 else 1;
}

fn runRestartDiagnostic(app: *const App) i32 {
    if (!queueDnsStatusResponse(app, request_id_stale_probe)) return fail(app, "queue probe failed");
    if (!verifyDnsStatus(app)) return fail(app, "dns status probe failed");
    if (!queueDnsStatusResponse(app, request_id_restart_test + 1)) return fail(app, "restart queue probe failed");
    if (!bindUdpForRestart(app)) return fail(app, "udp lifecycle probe failed");
    if (!listenTcpForRestart(app)) return fail(app, "tcp lifecycle probe failed");

    var response: [r4os.abi.ipc_max_message_size]u8 = .{0} ** r4os.abi.ipc_max_message_size;
    var status: i32 = 0;
    const payload = requestBackend(
        app,
        r4os.abi.ipc_channel_net_dns,
        r4os.abi.net_service_op_service_restart,
        request_id_restart_test,
        "",
        response[0..],
        &status,
    ) orelse return fail(app, "restart request failed");
    if (status != r4os.abi.net_service_result_ok or !startsWith(payload, "ok")) return fail(app, "restart result failed");
    if (!verifyRestartCleaned(app)) return fail(app, "restart cleanup status failed");

    app.sys.write("NETSVC restart-test: ");
    app.sys.write(payload);
    if (!endsWithNewline(payload)) app.sys.write("\r\n");
    return 0;
}

fn runDriverLifecycleDiagnostic(app: *const App) i32 {
    if (!true) return fail(app, "netdiag api missing");

    var result: r4os.abi.NetDiagResult = .{};
    const rc = app.net.netDiagRun(r4os.abi.net_diag_op_driver, &result);
    app.sys.write("NETSVC driver-lifecycle-test: ");
    app.sys.println(if (rc == r4os.abi.net_diag_ok) "ok" else "failed");
    app.sys.write("Driver lifecycle: tests=");
    printU(app, result.driver.tests);
    app.sys.write(" cases=");
    printU(app, result.driver.cases);
    app.sys.write("\r\n");
    printCleanup(app, result.cleanup);
    return if (rc == r4os.abi.net_diag_ok) 0 else 1;
}

fn queueDnsStatusResponse(app: *const App, request_id: u32) bool {
    var request: [r4os.abi.net_service_header_size]u8 = .{0} ** r4os.abi.net_service_header_size;
    writeNetServiceHeader(
        request[0..],
        r4os.abi.ipc_channel_net_dns,
        r4os.abi.net_service_op_dns_status_result,
        request_id,
        app.net.netServiceClientId(),
        r4os.abi.net_service_result_ok,
        0,
    ) orelse return false;
    return app.net.ipcSend(r4os.abi.ipc_channel_net_dns, request[0..]) > 0;
}

fn verifyDnsStatus(app: *const App) bool {
    var response: [r4os.abi.ipc_max_message_size]u8 = .{0} ** r4os.abi.ipc_max_message_size;
    var status: i32 = 0;
    const payload = requestBackend(
        app,
        r4os.abi.ipc_channel_net_dns,
        r4os.abi.net_service_op_dns_status_result,
        request_id_dns_probe,
        "",
        response[0..],
        &status,
    ) orelse return false;
    if (status != r4os.abi.net_service_result_ok) return false;
    var dns_status: r4os.abi.NetServiceDnsStatus = .{};
    return copyDnsStatus(payload, &dns_status);
}

fn bindUdpForRestart(app: *const App) bool {
    var request: [2]u8 = .{0} ** 2;
    writeU16(request[0..], 0, restart_test_udp_port);
    var response: [r4os.abi.ipc_max_message_size]u8 = .{0} ** r4os.abi.ipc_max_message_size;
    var status: i32 = 0;
    const payload = requestBackend(
        app,
        r4os.abi.ipc_channel_net_udp,
        r4os.abi.net_service_op_udp_bind_result,
        request_id_udp_probe,
        request[0..],
        response[0..],
        &status,
    ) orelse return false;
    if (status != r4os.abi.net_service_result_ok) return false;
    var result: r4os.abi.NetServiceUdpResult = .{};
    return copyUdpResult(payload, &result) and result.result == 0 and
        (result.flags & r4os.abi.net_service_udp_flag_handle_valid) != 0;
}

fn listenTcpForRestart(app: *const App) bool {
    var request: [2]u8 = .{0} ** 2;
    writeU16(request[0..], 0, restart_test_tcp_port);
    var response: [r4os.abi.ipc_max_message_size]u8 = .{0} ** r4os.abi.ipc_max_message_size;
    var status: i32 = 0;
    const payload = requestBackend(
        app,
        r4os.abi.ipc_channel_net_tcp,
        r4os.abi.net_service_op_tcp_listen_result,
        request_id_tcp_probe,
        request[0..],
        response[0..],
        &status,
    ) orelse return false;
    if (status != r4os.abi.net_service_result_ok) return false;
    var result: r4os.abi.NetServiceTcpResult = .{};
    return copyTcpResult(payload, &result) and result.result == 0 and
        (result.flags & r4os.abi.net_service_tcp_flag_listener) != 0;
}

fn verifyRestartCleaned(app: *const App) bool {
    var udp_status: r4os.abi.NetServiceUdpStatus = .{};
    if (!readUdpStatus(app, &udp_status)) return false;
    var tcp_status: r4os.abi.NetServiceTcpStatus = .{};
    if (!readTcpStatus(app, &tcp_status)) return false;
    return udp_status.active_sockets == 0 and
        tcp_status.active_listeners == 0 and
        tcp_status.handle_count == 0;
}

fn readUdpStatus(app: *const App, out: *r4os.abi.NetServiceUdpStatus) bool {
    var response: [r4os.abi.ipc_max_message_size]u8 = .{0} ** r4os.abi.ipc_max_message_size;
    var status: i32 = 0;
    const payload = requestBackend(
        app,
        r4os.abi.ipc_channel_net_udp,
        r4os.abi.net_service_op_udp_status_result,
        request_id_udp_probe + 1,
        "",
        response[0..],
        &status,
    ) orelse return false;
    return status == r4os.abi.net_service_result_ok and copyUdpStatus(payload, out);
}

fn readTcpStatus(app: *const App, out: *r4os.abi.NetServiceTcpStatus) bool {
    var response: [r4os.abi.ipc_max_message_size]u8 = .{0} ** r4os.abi.ipc_max_message_size;
    var status: i32 = 0;
    const payload = requestBackend(
        app,
        r4os.abi.ipc_channel_net_tcp,
        r4os.abi.net_service_op_tcp_status_result,
        request_id_tcp_probe + 1,
        "",
        response[0..],
        &status,
    ) orelse return false;
    return status == r4os.abi.net_service_result_ok and copyTcpStatus(payload, out);
}

fn requestBackend(
    app: *const App,
    channel_id: u32,
    op: u16,
    request_id: u32,
    payload_in: []const u8,
    response: []u8,
    status: *i32,
) ?[]const u8 {
    const got = app.net.netServiceRequest(channel_id, op, request_id, payload_in, response);
    if (got <= 0) return null;
    return app.net.netServicePayload(response[0..@intCast(got)], status);
}

fn copyDnsStatus(payload: []const u8, out: *r4os.abi.NetServiceDnsStatus) bool {
    if (payload.len < @sizeOf(r4os.abi.NetServiceDnsStatus)) return false;
    const bytes: [*]u8 = @ptrCast(out);
    @memcpy(bytes[0..@sizeOf(r4os.abi.NetServiceDnsStatus)], payload[0..@sizeOf(r4os.abi.NetServiceDnsStatus)]);
    return out.magic == r4os.abi.net_service_dns_status_magic and out.version == r4os.abi.net_service_dns_status_version;
}

fn copyUdpStatus(payload: []const u8, out: *r4os.abi.NetServiceUdpStatus) bool {
    if (payload.len < @sizeOf(r4os.abi.NetServiceUdpStatus)) return false;
    const bytes: [*]u8 = @ptrCast(out);
    @memcpy(bytes[0..@sizeOf(r4os.abi.NetServiceUdpStatus)], payload[0..@sizeOf(r4os.abi.NetServiceUdpStatus)]);
    return out.magic == r4os.abi.net_service_udp_status_magic and out.version == r4os.abi.net_service_udp_status_version;
}

fn copyTcpStatus(payload: []const u8, out: *r4os.abi.NetServiceTcpStatus) bool {
    if (payload.len < @sizeOf(r4os.abi.NetServiceTcpStatus)) return false;
    const bytes: [*]u8 = @ptrCast(out);
    @memcpy(bytes[0..@sizeOf(r4os.abi.NetServiceTcpStatus)], payload[0..@sizeOf(r4os.abi.NetServiceTcpStatus)]);
    return out.magic == r4os.abi.net_service_tcp_status_magic and out.version == r4os.abi.net_service_tcp_status_version;
}

fn copyUdpResult(payload: []const u8, out: *r4os.abi.NetServiceUdpResult) bool {
    if (payload.len < @sizeOf(r4os.abi.NetServiceUdpResult)) return false;
    const bytes: [*]u8 = @ptrCast(out);
    @memcpy(bytes[0..@sizeOf(r4os.abi.NetServiceUdpResult)], payload[0..@sizeOf(r4os.abi.NetServiceUdpResult)]);
    return out.magic == r4os.abi.net_service_udp_result_magic and out.version == r4os.abi.net_service_udp_result_version;
}

fn copyTcpResult(payload: []const u8, out: *r4os.abi.NetServiceTcpResult) bool {
    if (payload.len < @sizeOf(r4os.abi.NetServiceTcpResult)) return false;
    const bytes: [*]u8 = @ptrCast(out);
    @memcpy(bytes[0..@sizeOf(r4os.abi.NetServiceTcpResult)], payload[0..@sizeOf(r4os.abi.NetServiceTcpResult)]);
    return out.magic == r4os.abi.net_service_tcp_result_magic and out.version == r4os.abi.net_service_tcp_result_version;
}

fn printCleanup(app: *const App, cleanup: r4os.abi.NetDiagCleanup) void {
    app.sys.write("Cleanup: runs=");
    printU(app, cleanup.runs);
    app.sys.write(" link_down=");
    printU(app, cleanup.link_down_cleanups);
    app.sys.write(" reset=");
    printU(app, cleanup.adapter_reset_cleanups);
    app.sys.write(" unreg=");
    printU(app, cleanup.adapter_unregister_cleanups);
    app.sys.write(" svc_restart=");
    printU(app, cleanup.service_restart_cleanups);
    app.sys.write(" poweroff=");
    printU(app, cleanup.poweroff_cleanups);
    app.sys.write(" reboot=");
    printU(app, cleanup.reboot_cleanups);
    app.sys.write(" udp=");
    printU(app, cleanup.udp_sockets_closed);
    app.sys.write(" tcp=");
    printU(app, cleanup.tcp_connections_aborted);
    app.sys.write(" tcp_listen=");
    printU(app, cleanup.tcp_listeners_closed);
    app.sys.write(" dhcp=");
    printU(app, cleanup.dhcp_operations_cancelled);
    app.sys.write(" dns=");
    printU(app, cleanup.dns_operations_cancelled);
    app.sys.write(" last=");
    printFixed(app, cleanup.last_reason[0..]);
    app.sys.write("\r\n");
}

fn printFixed(app: *const App, value: []const u8) void {
    app.sys.write(spanZ(value));
}

fn spanZ(value: []const u8) []const u8 {
    var len: usize = 0;
    while (len < value.len and value[len] != 0) : (len += 1) {}
    return value[0..len];
}

fn printU(app: *const App, value: anytype) void {
    app.sys.printU64(@intCast(value));
}

fn fail(app: *const App, msg: []const u8) i32 {
    app.sys.write("NETSVC failed: ");
    app.sys.write(msg);
    app.sys.write("\r\n");
    return 1;
}

fn zSlice(value: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (value[len] != 0) : (len += 1) {}
    return value[0..len];
}

fn trim(value: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = value.len;
    while (start < end and isSpace(value[start])) : (start += 1) {}
    while (end > start and isSpace(value[end - 1])) : (end -= 1) {}
    return value[start..end];
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (upper(ca) != upper(cb)) return false;
    }
    return true;
}

fn startsWith(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and bytesEqual(value[0..prefix.len], prefix);
}

fn endsWithNewline(value: []const u8) bool {
    return value.len != 0 and (value[value.len - 1] == '\n' or value[value.len - 1] == '\r');
}

fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - 32;
    return ch;
}

fn writeNetServiceHeader(out: []u8, channel_id: u32, op: u16, request_id: u32, client_id: u16, status: i32, payload_len: u16) ?void {
    if (out.len < r4os.abi.net_service_header_size) return null;
    writeU32(out, 0, r4os.abi.net_service_magic);
    writeU16(out, 4, r4os.abi.net_service_version);
    writeU16(out, 6, @intCast(channel_id));
    writeU16(out, 8, op);
    writeU16(out, 10, 0);
    writeU32(out, 12, request_id);
    writeU16(out, 16, client_id);
    writeU16(out, 18, payload_len);
    writeI32(out, 20, status);
}

fn writeU16(out: []u8, offset: usize, value: u16) void {
    out[offset] = @intCast(value & 0xFF);
    out[offset + 1] = @intCast(value >> 8);
}

fn writeU32(out: []u8, offset: usize, value: u32) void {
    writeU16(out, offset, @intCast(value & 0xFFFF));
    writeU16(out, offset + 2, @intCast(value >> 16));
}

fn writeI32(out: []u8, offset: usize, value: i32) void {
    writeU32(out, offset, @bitCast(value));
}
