const std = @import("std");

pub const TitleFilter = struct {
    const State = enum {
        normal,
        esc,
        osc_type,
        osc_after_type,
        osc_body,
        osc_escape,
    };

    state: State = .normal,
    pending: [4]u8 = undefined,
    pending_len: usize = 0,

    pub fn filter(self: *TitleFilter, allocator: std.mem.Allocator, input: []const u8, output: *std.ArrayList(u8)) !void {
        for (input) |byte| {
            switch (self.state) {
                .normal => {
                    if (byte == 0x1b) {
                        self.pending_len = 0;
                        self.pending[self.pending_len] = byte;
                        self.pending_len += 1;
                        self.state = .esc;
                    } else {
                        try output.append(allocator, byte);
                    }
                },
                .esc => {
                    if (byte == ']') {
                        self.pending[self.pending_len] = byte;
                        self.pending_len += 1;
                        self.state = .osc_type;
                    } else {
                        try output.appendSlice(allocator, self.pending[0..self.pending_len]);
                        try output.append(allocator, byte);
                        self.pending_len = 0;
                        self.state = .normal;
                    }
                },
                .osc_type => {
                    if (byte == '0' or byte == '1' or byte == '2') {
                        self.pending[self.pending_len] = byte;
                        self.pending_len += 1;
                        self.state = .osc_after_type;
                    } else {
                        try output.appendSlice(allocator, self.pending[0..self.pending_len]);
                        try output.append(allocator, byte);
                        self.pending_len = 0;
                        self.state = .normal;
                    }
                },
                .osc_after_type => {
                    if (byte == ';') {
                        // Begin title sequence; discard pending bytes.
                        self.pending_len = 0;
                        self.state = .osc_body;
                    } else {
                        try output.appendSlice(allocator, self.pending[0..self.pending_len]);
                        try output.append(allocator, byte);
                        self.pending_len = 0;
                        self.state = .normal;
                    }
                },
                .osc_body => {
                    if (byte == 0x07) {
                        self.state = .normal;
                    } else if (byte == 0x1b) {
                        self.state = .osc_escape;
                    } else {
                        // discard title content
                    }
                },
                .osc_escape => {
                    if (byte == '\\') {
                        self.state = .normal;
                    } else if (byte == 0x1b) {
                        self.state = .osc_escape;
                    } else {
                        self.state = .osc_body;
                    }
                },
            }
        }
    }
};
