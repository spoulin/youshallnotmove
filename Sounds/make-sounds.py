#!/usr/bin/env python3
"""Synthesize the refusal sounds: short sci-fi interface beeps, as 16-bit mono WAV files.

Usage: python3 Sounds/make-sounds.py
"""
import math
import os
import struct
import wave

RATE = 44100
# Shifts every sound down (about 9 semitones): a deeper, starship-console voice.
PITCH = 0.6
HERE = os.path.dirname(os.path.abspath(__file__))


def soft_square(phase):
    """A rounded, slightly hollow timbre, like an old computer console."""
    return math.sin(phase) + 0.28 * math.sin(3 * phase) + 0.1 * math.sin(5 * phase)


def buzz(phase):
    """A rich timbre for the force field hum."""
    return sum(math.sin(k * phase) / k for k in range(1, 9))


def tone(freq, duration, timbre=soft_square, attack=0.004, release=0.03, tremolo=None):
    """freq is a number or a function of time; tremolo is (rate in Hz, depth 0..1)."""
    count = int(duration * RATE)
    samples = []
    phase = 0.0
    for i in range(count):
        t = i / RATE
        f = (freq(t) if callable(freq) else freq) * PITCH
        phase += 2 * math.pi * f / RATE
        envelope = min(1.0, t / attack, (duration - t) / release)
        value = timbre(phase) * max(0.0, envelope)
        if tremolo:
            rate, depth = tremolo
            value *= 1 - depth + depth * (0.5 + 0.5 * math.sin(2 * math.pi * rate * t))
        samples.append(value)
    return samples


def silence(duration):
    return [0.0] * int(duration * RATE)


def mix(*tracks):
    length = max(len(track) for track in tracks)
    return [sum(track[i] for track in tracks if i < len(track)) for i in range(length)]


def echo(samples, delay=0.07, gain=0.3, taps=3):
    """A few fading repeats, for the ship's corridor feel."""
    step = int(delay * RATE)
    out = samples + [0.0] * (step * taps)
    for k in range(1, taps + 1):
        g = gain ** k
        for i, value in enumerate(samples):
            out[i + step * k] += value * g
    return out


def write(name, samples):
    peak = max(abs(value) for value in samples) or 1.0
    frames = b"".join(struct.pack("<h", int(value / peak * 0.8 * 32767)) for value in samples)
    with wave.open(os.path.join(HERE, name + ".wav"), "w") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(frames)
    print("Wrote Sounds/%s.wav (%.2f s)" % (name, len(samples) / RATE))


# Two falling notes: the classic "access denied".
write("denied", echo(tone(1318.5, 0.07) + silence(0.02) + tone(880.0, 0.11, release=0.05)))

# A burbling downward sweep.
write("bwoop", echo(tone(lambda t: 1600 * (700 / 1600) ** (t / 0.16), 0.16, tremolo=(45, 0.5), release=0.05)))

# Three quick falling blips.
blips = []
for freq in (1760.0, 1568.0, 1396.9):
    blips += tone(freq, 0.035, release=0.015) + silence(0.018)
write("tripleBeep", echo(blips, gain=0.25, taps=2))

# A force field: a pulsing hum with a falling shimmer on top.
hum = tone(180.0, 0.28, timbre=buzz, attack=0.01, release=0.12, tremolo=(28, 0.8))
shimmer = [0.25 * v for v in tone(lambda t: 2400 - 2000 * t, 0.28, attack=0.01, release=0.12)]
write("forceField", echo(mix(hum, shimmer), gain=0.2, taps=2))
