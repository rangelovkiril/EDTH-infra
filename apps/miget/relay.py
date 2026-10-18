import asyncio
import base64
import hashlib
import logging
import os
import re
import ssl
import time

BROKER_HOST = os.environ.get("BROKER_HOST", "emqx.emqx.svc.cluster.local")
BROKER_PORT = int(os.environ.get("BROKER_PORT", "8883"))
BROKER_TLS = os.environ.get("BROKER_TLS", "1") != "0"
BROKER_TLS_NAME = os.environ.get("BROKER_TLS_NAME", "emqx.rangelov.dev")
VIEW_FPS = float(os.environ.get("VIEW_FPS", "10"))
PORT = int(os.environ.get("PORT", "8080"))
NODE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")
CONTENT_LENGTH_RE = re.compile(rb"content-length:\s*(\d+)", re.IGNORECASE)

log = logging.getLogger("relay")
frames: dict[str, tuple[int, bytes, float]] = {}
conditions: dict[str, asyncio.Condition] = {}
verified: dict[tuple[str, str], float] = {}


def condition(node: str) -> asyncio.Condition:
    return conditions.setdefault(node, asyncio.Condition())


def mqtt_connect_packet(user: str, password: str) -> bytes:
    def field(b: bytes) -> bytes:
        return len(b).to_bytes(2, "big") + b

    client_id = f"video-relay-{os.urandom(4).hex()}".encode()
    variable = field(b"MQTT") + bytes([4, 0xC2]) + (10).to_bytes(2, "big")
    payload = field(client_id) + field(user.encode()) + field(password.encode())
    remaining, encoded = len(variable) + len(payload), bytearray()
    while True:
        byte, remaining = remaining % 128, remaining // 128
        encoded.append(byte | (0x80 if remaining else 0))
        if not remaining:
            break
    return bytes([0x10]) + bytes(encoded) + variable + payload


async def broker_accepts(user: str, password: str) -> bool:
    key = (user, hashlib.sha256(password.encode()).hexdigest())
    if verified.get(key, 0) > time.time():
        return True
    tls = ssl.create_default_context() if BROKER_TLS else None
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(
                BROKER_HOST, BROKER_PORT, ssl=tls, server_hostname=BROKER_TLS_NAME if tls else None
            ),
            10,
        )
        writer.write(mqtt_connect_packet(user, password))
        await writer.drain()
        ack = await asyncio.wait_for(reader.readexactly(4), 10)
        writer.write(b"\xe0\x00")
        writer.close()
    except (OSError, TimeoutError, asyncio.IncompleteReadError, ssl.SSLError) as e:
        log.warning("event=broker_check_failed user=%s error=%s", user, e)
        return False
    ok = ack[0] == 0x20 and ack[3] == 0
    if ok:
        verified[key] = time.time() + 600
    return ok


async def body_chunks(reader: asyncio.StreamReader, headers: dict):
    if "chunked" in headers.get("transfer-encoding", "").lower():
        while True:
            size_line = await reader.readline()
            if not size_line:
                return
            size = int(size_line.split(b";")[0].strip() or b"0", 16)
            if size == 0:
                return
            data = await reader.readexactly(size)
            await reader.readexactly(2)
            yield data
    elif "content-length" in headers:
        left = int(headers["content-length"])
        while left > 0:
            data = await reader.read(min(left, 65536))
            if not data:
                return
            left -= len(data)
            yield data
    else:
        while data := await reader.read(65536):
            yield data


async def respond(writer, status: str, ctype: str, body: bytes, extra: str = "") -> None:
    writer.write(
        f"HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {len(body)}\r\n"
        f"Cache-Control: no-store\r\n{extra}Connection: close\r\n\r\n".encode() + body
    )
    await writer.drain()


async def push(node: str, reader, writer, headers: dict) -> None:
    auth = headers.get("authorization", "")
    user, password = "", ""
    if auth.lower().startswith("basic "):
        user, _, password = base64.b64decode(auth[6:]).decode(errors="replace").partition(":")
    if user != node or not await broker_accepts(user, password):
        log.warning("event=push_denied node=%s user=%s", node, user)
        await respond(writer, "401 Unauthorized", "text/plain", b"use the node's MQTT credentials\n",
                      'WWW-Authenticate: Basic realm="edth"\r\n')
        return
    log.info("event=push_start node=%s", node)
    buf, count = b"", 0
    async for chunk in body_chunks(reader, headers):
        buf += chunk
        while True:
            head_end = buf.find(b"\r\n\r\n")
            if head_end < 0:
                break
            match = CONTENT_LENGTH_RE.search(buf[:head_end])
            if not match:
                buf = buf[head_end + 4 :]
                continue
            start, length = head_end + 4, int(match.group(1))
            if len(buf) < start + length:
                break
            jpeg, buf = buf[start : start + length], buf[start + length :].lstrip(b"\r\n")
            count += 1
            cond = condition(node)
            async with cond:
                seq = frames.get(node, (0, b"", 0.0))[0] + 1
                frames[node] = (seq, jpeg, time.time())
                cond.notify_all()
    log.info("event=push_end node=%s frames=%d", node, count)
    await respond(writer, "200 OK", "text/plain", f"{count} frames\n".encode())


async def view(node: str, writer) -> None:
    writer.write(
        b"HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n"
        b"Cache-Control: no-store\r\nConnection: close\r\n\r\n"
    )
    seq, cond = 0, condition(node)
    while True:
        async with cond:
            try:
                await asyncio.wait_for(cond.wait_for(lambda: frames.get(node, (0,))[0] > seq), 5)
            except TimeoutError:
                pass
        if node not in frames:
            continue
        seq, jpeg, _ = frames[node]
        writer.write(
            b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
            + str(len(jpeg)).encode() + b"\r\n\r\n" + jpeg + b"\r\n"
        )
        await writer.drain()
        await asyncio.sleep(1 / VIEW_FPS)


def index() -> bytes:
    now = time.time()
    tiles = "".join(
        f'<figure><img src="/view/{n}"><figcaption>{n} · {now - t:.0f} s ago</figcaption></figure>'
        for n, (_, _, t) in sorted(frames.items())
    ) or "<p>No node is pushing video.</p>"
    return (
        "<!doctype html><meta charset=utf-8><title>EDTH video</title><style>"
        "body{background:#111;color:#ccc;font:14px sans-serif;display:flex;flex-wrap:wrap;gap:12px}"
        "img{max-width:640px;display:block}</style>" + tiles
    ).encode()


async def handle(reader, writer) -> None:
    try:
        line = await reader.readline()
        method, target, _ = line.decode("latin-1").split(" ", 2)
        headers = {}
        while (raw := await reader.readline()) not in (b"\r\n", b"\n", b""):
            name, _, value = raw.decode("latin-1").partition(":")
            headers[name.strip().lower()] = value.strip()
        parts = target.split("?")[0].strip("/").split("/")
        if method in ("POST", "PUT") and len(parts) == 2 and parts[0] == "push":
            if NODE_RE.match(parts[1]):
                await push(parts[1], reader, writer, headers)
            else:
                await respond(writer, "400 Bad Request", "text/plain", b"bad node id\n")
        elif method == "GET" and len(parts) == 2 and parts[0] == "view":
            node = parts[1].removesuffix(".jpg")
            if parts[1].endswith(".jpg"):
                if node in frames:
                    await respond(writer, "200 OK", "image/jpeg", frames[node][1])
                else:
                    await respond(writer, "404 Not Found", "text/plain", b"no video\n")
            elif NODE_RE.match(node):
                await view(node, writer)
        elif method == "GET" and parts == ["healthz"]:
            await respond(writer, "200 OK", "text/plain", b"ok\n")
        elif method == "GET" and parts == [""]:
            await respond(writer, "200 OK", "text/html; charset=utf-8", index())
        else:
            await respond(writer, "404 Not Found", "text/plain", b"not found\n")
    except (ConnectionError, ValueError, asyncio.IncompleteReadError):
        pass
    finally:
        writer.close()


async def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s level=%(levelname)s logger=%(name)s %(message)s",
    )
    server = await asyncio.start_server(handle, "0.0.0.0", PORT)
    log.info("event=start port=%d broker=%s:%d", PORT, BROKER_HOST, BROKER_PORT)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
