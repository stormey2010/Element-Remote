export function encodeFrame(bytes, mode = "tcp") {
  if (mode === "tcp") {
    const frame = Buffer.allocUnsafe(bytes.length + 4);
    frame.writeUInt32BE(bytes.length);
    bytes.copy(frame, 4);
    return frame;
  }
  const out = [0xc0];
  for (const byte of bytes) {
    if (byte === 0xc0) out.push(0xdb, 0xdc);
    else if (byte === 0xdb) out.push(0xdb, 0xdd);
    else out.push(byte);
  }
  out.push(0xc0);
  return Buffer.from(out);
}
export function createDecoder(onPacket, mode = "tcp", limit = 1024 * 1024) {
  let pending = Buffer.alloc(0),
    slip = [],
    escaped = false;
  return (chunk) => {
    if (mode === "tcp") {
      pending = Buffer.concat([pending, chunk]);
      if (pending.length > limit + 4)
        throw Error("OSC frame exceeds size limit");
      while (pending.length >= 4) {
        const length = pending.readUInt32BE(0);
        if (!length || length > limit) throw Error("Invalid OSC frame length");
        if (pending.length < length + 4) break;
        onPacket(pending.subarray(4, length + 4));
        pending = pending.subarray(length + 4);
      }
    } else
      for (const byte of chunk) {
        if (byte === 0xc0) {
          if (slip.length) onPacket(Buffer.from(slip));
          slip = [];
          escaped = false;
        } else if (escaped) {
          if (byte !== 0xdc && byte !== 0xdd)
            throw Error("Invalid SLIP escape");
          slip.push(byte === 0xdc ? 0xc0 : 0xdb);
          escaped = false;
        } else if (byte === 0xdb) escaped = true;
        else slip.push(byte);
        if (slip.length > limit) throw Error("OSC frame exceeds size limit");
      }
  };
}
