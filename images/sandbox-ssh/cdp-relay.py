#!/usr/bin/env python3
"""Expose Chromium's DevTools endpoint (bound to loopback) on 0.0.0.0:9222.

Chromium rejects DevTools requests whose Host header is not an IP address or
"localhost", and builds the advertised webSocketDebuggerUrl from that header.
The brain reaches us by Service name (<agent>-computer:9222), so the relay:
  * rewrites Host to the loopback upstream on the way in;
  * for /json* responses, rewrites the advertised ws:// address back to the
    name the client used, so the WebSocket attach goes through the relay too;
  * pipes WebSocket upgrades byte for byte after the rewritten handshake.
Only the agent's own brain can reach :9222 (NetworkPolicy).
"""
import asyncio
import os

LISTEN_PORT = int(os.environ.get("CDP_PORT", "9222"))
UP_HOST, UP_PORT = "127.0.0.1", int(os.environ.get("CHROMIUM_CDP_PORT", "9223"))
UPSTREAM = f"{UP_HOST}:{UP_PORT}".encode()


async def pipe(src, dst):
    try:
        while data := await src.read(65536):
            dst.write(data)
            await dst.drain()
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            dst.close()
        except Exception:
            pass


def reply(writer, status, body=b""):
    writer.write(b"HTTP/1.1 %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % (status, len(body), body))


async def handle(reader, writer):
    try:
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
    except Exception:
        writer.close()
        return
    lines = head[:-4].split(b"\r\n")
    client_host = b"localhost:%d" % LISTEN_PORT
    is_ws = False
    out = [lines[0]]
    for line in lines[1:]:
        name = line.split(b":", 1)[0].strip().lower()
        if name == b"host":
            client_host = line.split(b":", 1)[1].strip()
            out.append(b"Host: " + UPSTREAM)
        elif name == b"connection":
            is_ws = is_ws or b"upgrade" in line.lower()
            out.append(line)
        else:
            out.append(line)
    try:
        ur, uw = await asyncio.open_connection(UP_HOST, UP_PORT)
    except OSError:
        reply(writer, b"503 Service Unavailable", b"chromium not running\n")
        await writer.drain()
        writer.close()
        return

    if is_ws:
        uw.write(b"\r\n".join(out) + b"\r\n\r\n")
        await uw.drain()
        await asyncio.gather(pipe(reader, uw), pipe(ur, writer))
        return

    # Plain HTTP (/json/version, /json/list, ...): one request, then close.
    out = [l for l in out if not l.lower().startswith(b"connection:")] + [b"Connection: close"]
    uw.write(b"\r\n".join(out) + b"\r\n\r\n")
    await uw.drain()
    # Chromium ignores "Connection: close": read exactly Content-Length bytes.
    rhead = (await asyncio.wait_for(ur.readuntil(b"\r\n\r\n"), 10))[:-4]
    length = 0
    for h in rhead.split(b"\r\n")[1:]:
        if h.lower().startswith(b"content-length:"):
            length = int(h.split(b":", 1)[1])
    body = await asyncio.wait_for(ur.readexactly(length), 10) if length else b""
    uw.close()
    body = body.replace(UPSTREAM, client_host)
    hdrs = [h for h in rhead.split(b"\r\n") if not h.lower().startswith((b"content-length:", b"connection:"))]
    hdrs += [b"Content-Length: %d" % len(body), b"Connection: close"]
    writer.write(b"\r\n".join(hdrs) + b"\r\n\r\n" + body)
    await writer.drain()
    writer.close()


async def main():
    server = await asyncio.start_server(handle, "0.0.0.0", LISTEN_PORT)
    print(f"cdp-relay: 0.0.0.0:{LISTEN_PORT} -> {UP_HOST}:{UP_PORT}", flush=True)
    async with server:
        await server.serve_forever()


asyncio.run(main())
