#!/usr/bin/env python3
"""Synthesize original, short key sounds. No platform audio is sampled."""
import math
import random
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RATE = 44100

def make(name: str, duration: float, pitch: float, seed: int) -> None:
    noise = random.Random(seed)
    frames = []
    for index in range(int(RATE * duration)):
        t = index / RATE
        attack = min(1.0, t / 0.001)
        body = math.exp(-t * 155)
        transient = math.exp(-t * 580)
        tone = (math.sin(2 * math.pi * pitch * t) * 0.32 +
                math.sin(2 * math.pi * pitch * 1.63 * t) * 0.13)
        value = attack * (body * tone + transient * noise.uniform(-0.23, 0.23))
        frames.append(struct.pack('<h', int(max(-1, min(1, value)) * 32767)))
    with wave.open(str(ROOT / 'Resources' / name), 'wb') as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(b''.join(frames))

make('key-click-systemlike.wav', 0.026, 1830, 6101)
make('key-delete-systemlike.wav', 0.032, 1260, 6102)
