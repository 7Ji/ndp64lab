#!/usr/bin/env python3
"""One IPv6 TCP connection, no reconnects, with checked bidirectional payloads."""
import argparse
import json
import os
from pathlib import Path
import socket
import struct
import time


def publish(path, **state):
    temporary = path.with_suffix('.new')
    temporary.write_text(json.dumps(state))
    temporary.replace(path)


def receive(connection, size):
    result = bytearray()
    while len(result) < size:
        block = connection.recv(size - len(result))
        if not block:
            raise EOFError('TCP connection closed')
        result.extend(block)
    return bytes(result)


def server(args):
    with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((args.target, args.port))
        listener.listen(1)
        publish(args.state, status='listening', accepted=0)
        connection, peer = listener.accept()
    # Closing the listener makes reconnects impossible for this test.
    with connection:
        publish(args.state, status='connected', accepted=1, source=peer[0])
        while True:
            try:
                frame = receive(connection, 264)
            except EOFError:
                break
            connection.sendall(frame)
    publish(args.state, status='finished', accepted=1, source=peer[0])


def client(args):
    sequence = 0
    largest_gap = 0
    previous = time.monotonic()
    with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as connection:
        connection.settimeout(20)
        connection.bind((args.source, 0))
        connection.connect((args.target, args.port))
        local_port = connection.getsockname()[1]
        while not args.stop.exists():
            sequence += 1
            frame = struct.pack('!Q', sequence) + os.urandom(256)
            connection.sendall(frame)
            if receive(connection, len(frame)) != frame:
                raise ValueError('TCP payload differs from sent bytes')
            now = time.monotonic()
            largest_gap = max(largest_gap, now - previous)
            previous = now
            publish(args.state, status='running', sequence=sequence,
                    source=args.source, local_port=local_port,
                    largest_gap=largest_gap)
            time.sleep(0.1)
    publish(args.state, status='finished', sequence=sequence,
            source=args.source, local_port=local_port, largest_gap=largest_gap)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('server', 'client'))
    parser.add_argument('target')
    parser.add_argument('--source')
    parser.add_argument('--port', type=int, default=23456)
    parser.add_argument('--state', type=Path, default=Path('/tmp/roaming-state.json'))
    parser.add_argument('--stop', type=Path, default=Path('/tmp/roaming-stop'))
    args = parser.parse_args()
    try:
        (server if args.mode == 'server' else client)(args)
    except Exception as error:
        publish(args.state, status='error', error=str(error))
        raise
