const std = @import("std");
const http = std.http;
const log = std.log.scoped(.server);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const server_addr = "127.0.0.1";
    const server_port = 8000;

    var server = std.http.Server.init(allocator, .{
        .reuse_port = true,
    });

    log.info("Server is running at {s}:{d}", .{ server_addr, server_port });
    // Parse the server address.
    const address = std.net.Address.parseIp(server_addr, server_port) catch unreachable;
    try server.listen(address);

    runServer(&server, allocator) catch |err| {
        // Handle server errors.
        log.err("server error: {}\n", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        std.os.exit(1);
    };

    defer server.deinit();
}

fn handleRequest(response: *http.Server.Response, allocator: std.mem.Allocator) !void {
    // Log the request details.
    log.info("{s} {s} {s}", .{ @tagName(response.request.method), @tagName(response.request.version), response.request.target });

    // Set "connection" header to "keep-alive" if present in request headers.
    if (response.request.headers.contains("connection")) {
        try response.headers.append("connection", "keep-alive");
    }

    // Create an HTTP client.
    var client = http.Client{ .allocator = allocator };
    // Release all associated resources with the client.
    defer client.deinit();

    // Parse the URI.
    const uri = std.Uri.parse(try concatAndReturnBuffer(allocator, "http://localhost:3000", response.request.target)) catch unreachable;

    // Create the headers that will be sent to the server.
    var request_headers = std.http.Headers{ .allocator = allocator };
    defer request_headers.deinit();
    // Accept anything.
    try request_headers.append("accept", "*/*");
    // Make the connection to the server.
    var request = client.request(.GET, uri, request_headers, .{}) catch |err| switch (err) {
        error.ConnectionRefused => {
            response.status = .service_unavailable;
            const error_response_text = @embedFile("pages/service_unavailable.html");
            try response.headers.append("content-length", try std.fmt.allocPrint(allocator, "{d}", .{error_response_text.len}));
            try response.do();
            try response.writeAll(error_response_text);
            try response.finish();
            return;
        },
        else => return err,
    };
    defer request.deinit();

    try request.start();
    try request.wait();

    const request_body = try request.reader().readAllAlloc(allocator, 3 * 5e+6);
    log.debug("request body length is {s}!", .{try std.fmt.allocPrint(allocator, "{d}", .{request_body.len})});

    try response.headers.append("content-length", try std.fmt.allocPrint(allocator, "{d}", .{request_body.len}));

    try response.do();
    try response.writeAll(request_body);
    try response.finish();
}

/// `type` is either a `[]u8` or `[]const u8`.
fn concatAndReturnBuffer(allocator: std.mem.Allocator, one: []const u8, two: []const u8) ![]const u8 {
    var result = try allocator.alloc(u8, one.len + two.len);
    std.mem.copy(u8, result, one);
    std.mem.copy(u8, result[one.len..], two);
    return result;
}

// Run the server and handle incoming requests.
fn runServer(server: *http.Server, allocator: std.mem.Allocator) !void {
    outer: while (true) {
        // Accept incoming connection.
        var response = try server.accept(.{
            .allocator = allocator,
        });
        defer response.deinit();

        while (response.reset() != .closing) {
            // Handle errors during request processing.
            response.wait() catch |err| switch (err) {
                error.HttpHeadersInvalid => continue :outer,
                error.EndOfStream => continue,
                else => return err,
            };

            // Process the request.
            try handleRequest(&response, allocator);
        }
    }
}
