const PORT_COM1: u16 = 0x3F8;

// Read a byte from an I/O port
fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

// Write a byte to an I/O port
fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

pub fn initSerial() void {
    // Disable interrupts
    outb(PORT_COM1 + 1, 0x00);

    // Enable DLAB
    outb(PORT_COM1 + 3, 0x80);

    // Divisor = 3 -> 38400 baud
    outb(PORT_COM1 + 0, 0x03);
    outb(PORT_COM1 + 1, 0x00);

    // 8 bits, no parity, one stop bit
    outb(PORT_COM1 + 3, 0x03);

    // Enable FIFO, clear FIFOs, 14-byte threshold
    outb(PORT_COM1 + 2, 0xC7);

    // Modem control: RTS + DTR
    outb(PORT_COM1 + 4, 0x03);
}

fn isTransmitEmpty() bool {
    // Bit 5 (0x20) is Transmitter Holding Register Empty (THRE)
    return (inb(PORT_COM1 + 5) & 0x20) != 0;
}

pub fn writeChar(a: u8) void {
    // CRUCIAL: Wait until the port is ready for a new byte
    while (!isTransmitEmpty()) {
        // Optional: asm volatile ("pause");
    }
    outb(PORT_COM1, a);
}

pub fn writeString(s: []const u8) void {
    for (s) |c| {
        writeChar(c);
    }
}
